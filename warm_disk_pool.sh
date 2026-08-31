#!/usr/bin/env bash
#
# Warm cache disk pool manager for ephemeral GCE GitHub Actions runner VMs.
#
# A pool is a set of persistent disks in one zone sharing the label `pool=<name>`.
# The pool name doubles as the cache key: pass a different name to get a different
# pool. Pools are per zone by construction because the disk listing is zone scoped.
#
#   acquire   grab a free disk from the pool and mount it (run before the runner
#             registers, so the cache is ready for every step of the job)
#   release   prune, unmount, refresh the golden snapshot and hand the disk back
#             (run just before the VM deletes itself)
#   gc        housekeeping that the release path cannot do: recover disks orphaned
#             by an abrupt VM death. Optional, meant for a scheduled workflow.
#
# Locking is provided by Compute Engine itself: a zonal persistent disk can only be
# attached read-write to one instance at a time, so a successful attach *is* the
# lock. There is no external lock service, and `--force-attach` must never be used
# because it would break that guarantee.
#
# Disks are never deleted by the instance-delete path: `gcloud compute instances
# attach-disk` has no --auto-delete flag, so attached disks keep autoDelete=false
# and are detached, not destroyed, when the VM goes away.

set -o errexit -o pipefail -o nounset

readonly DEVICE_NAME="warm-cache"
readonly DEV="/dev/disk/by-id/google-${DEVICE_NAME}"
readonly ENV_FILE="${WARM_DISK_POOL_ENV_FILE:-/etc/warm-disk-pool.env}"

# Upper bound on how many surplus disks a single release may delete. Keeps a
# misbehaving pool from being emptied in one go.
readonly MAX_TRIM_PER_RUN=2
# Golden snapshot generations to keep.
readonly SNAPSHOT_GENERATIONS=3

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

POOL="${CACHE_DISK_POOL:-}"
ZONE="${CACHE_DISK_ZONE:-}"
VM="${CACHE_DISK_VM:-}"
MOUNT_POINT="${CACHE_DISK_MOUNT_POINT:-/mnt/cache}"
DISK_SIZE="${CACHE_DISK_SIZE:-500GB}"
DISK_TYPE="${CACHE_DISK_TYPE:-pd-balanced}"
MIN_POOL_SIZE="${CACHE_DISK_MIN_POOL_SIZE:-2}"
IDLE_TTL_HOURS="${CACHE_DISK_IDLE_TTL_HOURS:-24}"
PRUNE_THRESHOLD="${CACHE_DISK_PRUNE_THRESHOLD:-80}"
SNAPSHOT_REFRESH_HOURS="${CACHE_DISK_SNAPSHOT_REFRESH_HOURS:-24}"

export CLOUDSDK_CONFIG="${CLOUDSDK_CONFIG:-/tmp}"

# Everything logs to stderr so that stdout stays clean for functions that return
# a value, such as create_pool_disk.
function log {
  echo "[warm-disk-pool] $*" >&2
}

function warn {
  echo "[warm-disk-pool] WARNING: $*" >&2
}

function now_epoch {
  date +%s
}

# Compute Engine label values accept lowercase letters, numbers, dashes and
# underscores only. Reject anything else instead of silently normalising it,
# because normalisation could collide two distinct cache keys onto one pool.
function validate_pool_name {
  if [[ ! "${POOL}" =~ ^[a-z0-9_-]{1,63}$ ]]; then
    warn "invalid cache_disk_pool '${POOL}'."
    warn "It must match ^[a-z0-9_-]{1,63}\$ to be usable as a Compute Engine label value."
    return 1
  fi
}

function require_config {
  local missing=()
  [[ -n "${POOL}" ]] || missing+=("CACHE_DISK_POOL")
  [[ -n "${ZONE}" ]] || missing+=("CACHE_DISK_ZONE")
  [[ -n "${VM}" ]] || missing+=("CACHE_DISK_VM")
  if [[ ${#missing[@]} -gt 0 ]]; then
    warn "missing configuration: ${missing[*]}"
    return 1
  fi
  validate_numeric_config
}

# These values end up in arithmetic contexts, where a non-numeric value would
# abort the script and a negative one would make trim destructive. Check them once,
# up front, rather than discovering the problem halfway through a release.
function validate_numeric_config {
  local name value
  for name in MIN_POOL_SIZE IDLE_TTL_HOURS PRUNE_THRESHOLD SNAPSHOT_REFRESH_HOURS; do
    value="${!name}"
    if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
      warn "${name} must be a non-negative integer, got '${value}'"
      return 1
    fi
  done
  if [[ "${PRUNE_THRESHOLD}" -gt 100 ]]; then
    warn "PRUNE_THRESHOLD must be a percentage, got '${PRUNE_THRESHOLD}'"
    return 1
  fi
}

# Lists the pool as JSON. Returns non-zero when the API call itself fails.
#
# Distinguishing "the listing failed" from "the pool is empty" is the single most
# important guard in this script: if a permission problem made a failed listing
# look like an empty pool, every VM would create a brand new disk and the pool
# would grow without bound. Note that a size cap could not protect against this,
# since counting the pool uses the very same listing.
function list_pool_json {
  local json
  json=$(gcloud compute disks list \
    --filter="labels.pool=${POOL}" \
    --zones="${ZONE}" \
    --format=json) || return 1
  echo "${json}" | jq '[ .[] | select(.labels.state != "quarantined") ]'
}

function jq_free_disks {
  jq -r '.[] | select((.users // []) | length == 0) | .name'
}

function set_disk_labels {
  local disk="${1}" labels="${2}"
  gcloud compute disks add-labels "${disk}" --zone="${ZONE}" \
    --labels="${labels}" > /dev/null 2>&1 || \
    warn "could not update labels on ${disk}"
}

# Name of the pool disk currently attached to this VM, empty when there is none.
function attached_disk_name {
  gcloud compute instances describe "${VM}" --zone="${ZONE}" --format=json 2>/dev/null |
    jq -r --arg dev "${DEVICE_NAME}" \
      '.disks // [] | map(select(.deviceName == $dev)) | .[0].source // "" | split("/") | last' \
    || true
}

function newest_pool_snapshot {
  gcloud compute snapshots list \
    --filter="labels.pool=${POOL}" \
    --sort-by=~creationTimestamp \
    --limit=1 \
    --format="value(name)" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# acquire
# ---------------------------------------------------------------------------

function wait_for_device {
  local waited=0
  while [[ ! -e "${DEV}" ]]; do
    if [[ ${waited} -ge 30 ]]; then
      warn "device ${DEV} did not appear within 30s"
      return 1
    fi
    sleep 1
    waited=$(( waited + 1 ))
  done
}

# Makes sure the filesystem is usable before we mount it. A VM that died without
# unmounting leaves a dirty journal behind, so replay it here rather than letting
# the next job trip over half written cache entries.
function ensure_filesystem {
  if ! blkid "${DEV}" > /dev/null 2>&1; then
    log "  ${DEV} has no filesystem, creating ext4"
    # errexit is suppressed here because the caller invokes this inside an `if !`,
    # so the failure has to be returned explicitly.
    mkfs.ext4 -q -L warmcache "${DEV}" || return 1
    return 0
  fi

  local state
  state=$(tune2fs -l "${DEV}" 2>/dev/null | sed -n 's/^Filesystem state: *//p' || true)
  if [[ "${state}" != "clean" ]]; then
    log "  filesystem state is '${state:-unknown}', running fsck"
    local rc=0
    fsck -p "${DEV}" || rc=$?
    # fsck exits 0 when the filesystem was already clean and 1 when it repaired
    # everything it found. Anything else means errors were left behind.
    if [[ "${rc}" -gt 1 ]]; then
      warn "  fsck left errors on ${DEV} (exit ${rc})"
      return 1
    fi
  fi
}

function quarantine_disk {
  local disk="${1}"
  warn "  quarantining ${disk} so other VMs stop picking it"
  set_disk_labels "${disk}" "state=quarantined"
}

function attach_and_mount {
  local disk="${1}"

  gcloud compute instances attach-disk "${VM}" \
    --disk="${disk}" \
    --device-name="${DEVICE_NAME}" \
    --zone="${ZONE}" > /dev/null 2>&1 || return 1

  if ! wait_for_device || ! ensure_filesystem; then
    quarantine_disk "${disk}"
    gcloud compute instances detach-disk "${VM}" --disk="${disk}" --zone="${ZONE}" \
      > /dev/null 2>&1 || true
    return 1
  fi

  mkdir -p "${MOUNT_POINT}"
  # relatime rather than noatime: prune evicts by access time, so atime has to
  # keep moving.
  if ! mount -o defaults,relatime,discard "${DEV}" "${MOUNT_POINT}"; then
    quarantine_disk "${disk}"
    gcloud compute instances detach-disk "${VM}" --disk="${disk}" --zone="${ZONE}" \
      > /dev/null 2>&1 || true
    return 1
  fi
}

function create_pool_disk {
  local disk="warm-${POOL}-$(tr -dc 'a-z0-9' < /dev/urandom | head -c 8)"
  local snapshot
  snapshot=$(newest_pool_snapshot)

  if [[ -n "${snapshot}" ]]; then
    log "  creating ${disk} from snapshot ${snapshot}"
    gcloud compute disks create "${disk}" \
      --zone="${ZONE}" \
      --source-snapshot="${snapshot}" \
      --type="${DISK_TYPE}" \
      --labels="pool=${POOL},last_used=$(now_epoch)" > /dev/null || return 1
  else
    log "  no golden snapshot for pool '${POOL}', creating empty ${disk}"
    gcloud compute disks create "${disk}" \
      --zone="${ZONE}" \
      --size="${DISK_SIZE}" \
      --type="${DISK_TYPE}" \
      --labels="pool=${POOL},last_used=$(now_epoch)" > /dev/null || return 1
  fi

  echo "${disk}"
}

function acquire {
  if [[ -z "${POOL}" ]]; then
    return 0
  fi
  require_config || return 0
  validate_pool_name || return 1

  if mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
    log "${MOUNT_POINT} is already mounted, nothing to do"
    return 0
  fi

  local disks_json
  if ! disks_json=$(list_pool_json); then
    # Never create a disk when the pool state is unknown.
    warn "could not list pool '${POOL}' in ${ZONE}. Continuing without a cache disk."
    return 0
  fi

  local candidates
  if ! candidates=$(echo "${disks_json}" | jq_free_disks | shuf); then
    # An enumeration failure is not the same as an exhausted pool. Creating a disk
    # here would grow the pool without bound every time jq or shuf misbehaves.
    warn "could not enumerate free disks in pool '${POOL}'. Continuing without a cache disk."
    return 0
  fi

  local disk
  for disk in ${candidates}; do
    log "trying to acquire ${disk}"
    if attach_and_mount "${disk}"; then
      log "✅ acquired ${disk} at ${MOUNT_POINT}"
      mkdir -p "${MOUNT_POINT}/bazel" "${MOUNT_POINT}/dvc"
      return 0
    fi
  done

  # Every disk is taken, so the pool is smaller than the current concurrency.
  # Grow it. The pool can never exceed the peak number of concurrent runner VMs,
  # because a disk is only ever created when all existing ones are held.
  log "pool '${POOL}' is exhausted in ${ZONE}, growing it"
  if ! disk=$(create_pool_disk); then
    warn "could not create a pool disk. Continuing without a cache disk."
    return 0
  fi
  if attach_and_mount "${disk}"; then
    log "✅ acquired freshly created ${disk} at ${MOUNT_POINT}"
    mkdir -p "${MOUNT_POINT}/bazel" "${MOUNT_POINT}/dvc"
    return 0
  fi

  warn "could not attach ${disk}. Continuing without a cache disk."
  return 0
}

# ---------------------------------------------------------------------------
# release
# ---------------------------------------------------------------------------

# Bazel's disk cache has no built in eviction, so it grows without bound. Drop the
# least recently used entries when the disk gets full. This runs on the way out so
# that it never delays the start of a job.
function prune_cache {
  local usage
  usage=$(df --output=pcent "${MOUNT_POINT}" 2>/dev/null | tail -1 | tr -dc '0-9' || true)
  [[ -n "${usage}" ]] || return 0
  if [[ "${usage}" -le "${PRUNE_THRESHOLD}" ]]; then
    return 0
  fi

  log "usage is ${usage}% (threshold ${PRUNE_THRESHOLD}%), pruning"
  local days
  for days in 30 14 7 3 1; do
    find "${MOUNT_POINT}" -type f -atime +"${days}" -delete 2>/dev/null || true
    usage=$(df --output=pcent "${MOUNT_POINT}" 2>/dev/null | tail -1 | tr -dc '0-9' || true)
    log "  after dropping entries older than ${days}d: ${usage}%"
    if [[ -n "${usage}" && "${usage}" -le "${PRUNE_THRESHOLD}" ]]; then
      break
    fi
  done
}

function unmount_cache {
  sync
  if umount "${MOUNT_POINT}" 2>/dev/null; then
    return 0
  fi
  warn "${MOUNT_POINT} is busy, killing the processes holding it"
  fuser -km "${MOUNT_POINT}" 2>/dev/null || true
  sleep 2
  sync
  umount "${MOUNT_POINT}" 2>/dev/null || {
    warn "could not unmount ${MOUNT_POINT}. The next VM to pick this disk will fsck it."
    return 1
  }
}

# Refreshes the golden snapshot used to seed brand new pool disks. Snapshotting a
# disk that we have just cleanly unmounted gives the warmest possible seed, so no
# separate warming job is needed.
function refresh_snapshot {
  local disk="${1}"
  local newest created_iso created_epoch age_hours
  newest=$(newest_pool_snapshot)

  if [[ -n "${newest}" ]]; then
    created_iso=$(gcloud compute snapshots describe "${newest}" \
      --format="value(creationTimestamp)" 2>/dev/null || echo "")
    created_epoch=$(date -d "${created_iso}" +%s 2>/dev/null || echo "")
    if [[ -n "${created_epoch}" ]]; then
      age_hours=$(( ( $(now_epoch) - created_epoch ) / 3600 ))
      if [[ "${age_hours}" -lt "${SNAPSHOT_REFRESH_HOURS}" ]]; then
        return 0
      fi
    fi
  fi

  log "refreshing the golden snapshot for pool '${POOL}'"
  gcloud compute disks snapshot "${disk}" \
    --zone="${ZONE}" \
    --snapshot-names="warm-${POOL}-$(now_epoch)" \
    --labels="pool=${POOL}" \
    --async > /dev/null 2>&1 || {
      warn "could not start a snapshot of ${disk}"
      return 0
    }

  local stale
  stale=$(gcloud compute snapshots list \
    --filter="labels.pool=${POOL}" \
    --sort-by=~creationTimestamp \
    --format="value(name)" 2>/dev/null | tail -n +$(( SNAPSHOT_GENERATIONS + 1 )) || true)
  local snap
  for snap in ${stale}; do
    log "  deleting stale snapshot ${snap}"
    gcloud --quiet compute snapshots delete "${snap}" > /dev/null 2>&1 || true
  done
}

# Scale-in. The pool grows to the peak concurrency of the workflows using it, so
# after a burst it stays larger than the steady state needs. Trim the surplus while
# the burst is draining, which is exactly when release is being called repeatedly.
# A floor keeps some disks warm for the next job.
#
# Concurrent releases each compute their budget from their own listing, so the
# floor is approximate: a burst draining all at once can briefly overshoot it. That
# is deliberate. Serialising this would need a lock, and the cost of overshooting
# is only that the next job restores a disk from the golden snapshot. A disk that
# somebody else has already acquired cannot be deleted at all, because Compute
# Engine refuses to delete an attached disk.
function trim_pool {
  local disks_json
  if ! disks_json=$(list_pool_json); then
    warn "could not list pool '${POOL}', skipping trim"
    return 0
  fi

  local pool_size
  pool_size=$(echo "${disks_json}" | jq -r 'length' || true)
  [[ -n "${pool_size}" ]] || return 0
  if [[ "${pool_size}" -le "${MIN_POOL_SIZE}" ]]; then
    return 0
  fi

  local cutoff
  cutoff=$(( $(now_epoch) - IDLE_TTL_HOURS * 3600 ))

  # Free disks that have not been used since the cutoff, oldest first. Every pool
  # disk is stamped with last_used when it is created and again on every release,
  # so a disk without the label has been tampered with and is left alone.
  local stale
  stale=$(echo "${disks_json}" | jq -r --argjson cutoff "${cutoff}" '
    [ .[]
      | select((.users // []) | length == 0)
      | select(.labels.last_used != null)
      | { name: .name, used: (.labels.last_used | tonumber) }
      | select(.used < $cutoff) ]
    | sort_by(.used) | .[].name')

  local deletable=$(( pool_size - MIN_POOL_SIZE ))
  local budget=$(( deletable < MAX_TRIM_PER_RUN ? deletable : MAX_TRIM_PER_RUN ))
  local disk
  for disk in ${stale}; do
    [[ "${budget}" -gt 0 ]] || break
    log "trimming idle disk ${disk}"
    # A disk that another VM grabbed in the meantime is still in use, and Compute
    # Engine refuses to delete it. That is the outcome we want, so ignore failures.
    gcloud --quiet compute disks delete "${disk}" --zone="${ZONE}" > /dev/null 2>&1 || true
    budget=$(( budget - 1 ))
  done
}

function release {
  if [[ -z "${POOL}" ]]; then
    return 0
  fi
  require_config || return 0

  # release runs from both the self delete path and the guest shutdown script, so
  # it has to be idempotent.
  if ! mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
    return 0
  fi

  local disk
  disk=$(attached_disk_name)
  if [[ -z "${disk}" ]]; then
    warn "no disk with device name ${DEVICE_NAME} is attached to ${VM}"
    umount "${MOUNT_POINT}" 2>/dev/null || true
    return 0
  fi

  log "releasing ${disk}"
  prune_cache || true
  local unmounted="false"
  if unmount_cache; then
    unmounted="true"
  fi
  set_disk_labels "${disk}" "last_used=$(now_epoch)"
  # Only snapshot a disk we know is quiesced, otherwise the golden image would seed
  # new pool disks with a dirty filesystem.
  if [[ "${unmounted}" == "true" ]]; then
    refresh_snapshot "${disk}" || true
  fi

  # Detaching is not required for correctness, since deleting the instance detaches
  # it anyway, but doing it here returns the disk to the pool sooner. Only do it
  # once the filesystem is quiesced: handing a still-mounted disk back would let
  # another VM attach it underneath us and corrupt it.
  if [[ "${unmounted}" == "true" ]]; then
    gcloud compute instances detach-disk "${VM}" --disk="${disk}" --zone="${ZONE}" \
      > /dev/null 2>&1 || true
  else
    warn "leaving ${disk} attached; it will be detached when the instance is deleted"
  fi

  trim_pool || true
  log "✅ released ${disk}"
}

# ---------------------------------------------------------------------------
# gc
# ---------------------------------------------------------------------------

# Recovers disks left attached to an instance that no longer exists. Compute Engine
# detaches disks when an instance is deleted, so this only matters when a VM dies
# abruptly (host failure). Everything else is handled by release.
function gc {
  [[ -n "${POOL}" && -n "${ZONE}" ]] || {
    warn "CACHE_DISK_POOL and CACHE_DISK_ZONE are required"
    return 1
  }
  validate_pool_name || return 1
  validate_numeric_config || return 1

  local disks_json
  if ! disks_json=$(list_pool_json); then
    warn "could not list pool '${POOL}' in ${ZONE}"
    return 1
  fi

  # If we cannot tell which instances are alive we must not detach anything, or we
  # would rip disks out from under running jobs.
  local live
  if ! live=$(gcloud compute instances list --zones="${ZONE}" --format="value(name)"); then
    warn "could not list instances in ${ZONE}, refusing to detach anything"
    return 1
  fi

  local entry disk holder
  while read -r entry; do
    [[ -n "${entry}" ]] || continue
    disk="${entry%% *}"
    holder="${entry#* }"
    if ! echo "${live}" | grep -qx "${holder}"; then
      log "detaching ${disk} from vanished instance ${holder}"
      gcloud compute instances detach-disk "${holder}" --disk="${disk}" --zone="${ZONE}" \
        > /dev/null 2>&1 || true
    fi
  done <<< "$(echo "${disks_json}" | jq -r '
    .[] | select((.users // []) | length > 0)
        | "\(.name) \(.users[0] | split("/") | last)"')"

  reap_quarantined
  trim_pool
}

# Disks whose filesystem could not be repaired are labelled state=quarantined and
# skipped by acquire, which means nothing else will ever touch them again. They
# hold nothing but cache, so once they have been idle long enough to be sure no VM
# is mid-acquire on them, delete them rather than paying for them forever.
function reap_quarantined {
  local json
  if ! json=$(gcloud compute disks list \
    --filter="labels.pool=${POOL} AND labels.state=quarantined" \
    --zones="${ZONE}" --format=json); then
    warn "could not list quarantined disks in pool '${POOL}'"
    return 0
  fi

  local cutoff
  cutoff=$(( $(now_epoch) - IDLE_TTL_HOURS * 3600 ))

  local doomed disk
  doomed=$(echo "${json}" | jq -r --argjson cutoff "${cutoff}" '
    .[] | select((.users // []) | length == 0)
        | select(.labels.last_used != null)
        | select((.labels.last_used | tonumber) < $cutoff)
        | .name' || true)

  for disk in ${doomed}; do
    log "deleting quarantined disk ${disk}"
    gcloud --quiet compute disks delete "${disk}" --zone="${ZONE}" > /dev/null 2>&1 || true
  done
}

# ---------------------------------------------------------------------------

function usage {
  echo "Usage: ${0} <acquire|release|gc>"
}

case "${1:-}" in
  acquire) acquire ;;
  release) release ;;
  gc)      gc ;;
  *)       usage; exit 1 ;;
esac
