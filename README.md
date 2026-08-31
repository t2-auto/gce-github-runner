# gce-github-runner
[![awesome-runners](https://img.shields.io/badge/listed%20on-awesome--runners-blue.svg)](https://github.com/jonico/awesome-runners)
[![Pre-commit](https://github.com/related-sciences/gce-github-runner/actions/workflows/pre_commit.yml/badge.svg?branch=main)](https://github.com/related-sciences/gce-github-runner/actions/workflows/pre_commit.yml)
[![Test](https://github.com/related-sciences/gce-github-runner/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/related-sciences/gce-github-runner/actions/workflows/test.yml)

Ephemeral GCE GitHub self-hosted runner.

## Usage

```yaml
jobs:
  create-runner:
    runs-on: ubuntu-latest
    outputs:
      label: ${{ steps.create-runner.outputs.label }}
    steps:
      - id: create-runner
        uses: related-sciences/gce-github-runner@v0.9
        with:
          token: ${{ secrets.GH_SA_TOKEN }}
          project_id: ${{ secrets.GCP_PROJECT_ID }}
          service_account_key: ${{ secrets.GCP_SA_KEY }}
          image_project: ubuntu-os-cloud
          image_family: ubuntu-2004-lts

  test:
    needs: create-runner
    runs-on: ${{ needs.create-runner.outputs.label }}
    steps:
      - run: echo "This runs on the GCE VM"
```

 * `create-runner` creates the GCE VM and registers the runner with unique label
 * `test` uses the runner
 * the runner VM will be automatically shut down after the workflow via [self-hosted runner hook](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/running-scripts-before-or-after-a-job)

## Inputs

See inputs and descriptions [here](./action.yml).

The GCE runner image should have at least:
 * `gcloud`
 * `git`
 * (optionally) GitHub Actions Runner (see `actions_preinstalled` parameter)

## Warm cache disk pool

Ephemeral runners start from a clean image every time, so anything a job caches on
local disk is thrown away when the VM deletes itself. For workloads with a large
local cache — a Bazel `--disk_cache`, a DVC cache, a container layer store — that
cold start can dominate the job.

Set `cache_disk_pool` to keep the cache on a pool of persistent disks that outlive
the VMs:

```yaml
- uses: t2-auto/gce-github-runner@deep-learning-vm-iamge
  with:
    cache_disk_pool: my-repo-bazel
    cache_disk_mount_point: /mnt/cache
```

Each VM checks a disk out of the pool at startup and hands it back just before it
deletes itself. Compute Engine only lets one instance attach a zonal disk
read-write at a time, so a successful attach *is* the lock; there is no external
coordination and no lease to expire.

The pool grows and shrinks on its own. When a VM finds every disk taken it creates
a new one, seeded from the pool's golden snapshot so it starts warm rather than
empty. That snapshot is refreshed on release, from a disk that was just cleanly
unmounted. Because a disk is only ever created when all the others are held, the
pool cannot grow past the peak number of concurrent runner VMs. On the way back
down, each release removes at most a couple of disks that have been idle longer
than `cache_disk_idle_ttl_hours`, never dropping below
`cache_disk_min_pool_size`. Trimming on release rather than on a timer is
deliberate: it returns the pool to its baseline while a burst is draining, instead
of emptying it over a quiet weekend and leaving Monday morning cold.

Since a disk cache has no eviction of its own, `cache_disk_prune_threshold` caps
how full a disk may get; older entries are dropped on release, so pruning never
delays the start of a job.

**The pool name is the cache key.** Two workflows that share a name share their
cached data, which is usually what you want — the more jobs share a pool, the
warmer every disk stays and the fewer disks you pay for. Split pools only along
axes that genuinely cannot share data, such as CPU architecture or toolchain
version, and keep the key low cardinality and stable. Deriving it from something
like `hashFiles()` would create a fresh, permanently cold pool on every change.

Only one case is beyond the reach of `release`: a VM that dies abruptly, taking its
disk with it. Compute Engine detaches disks when an instance is deleted, so this
only happens on a host failure. The manager exposes a `gc` subcommand for that,
which detaches disks held by instances that no longer exist and reaps disks that
were quarantined. It is meant for an occasional scheduled workflow and is not
required for normal operation.

Nothing here can fail a job. If the pool cannot be listed, every disk is taken and
a new one cannot be created, or the filesystem is unusable, the job simply runs
without a cache. A disk whose filesystem cannot be repaired is labelled
`state=quarantined` and skipped by later jobs instead of being handed out again.

### Required IAM

The runner VM's service account manages the pool itself, so it needs, on top of
what the action already requires:

* `compute.disks.create`, `compute.disks.use`, `compute.disks.delete`,
  `compute.disks.setLabels`, `compute.disks.list`, `compute.disks.get`
* `compute.instances.attachDisk`, `compute.instances.detachDisk`
* `compute.snapshots.create`, `compute.snapshots.useReadOnly`,
  `compute.snapshots.delete`, `compute.snapshots.list`, `compute.snapshots.get`

Note that these VMs run whatever code the workflow gives them, including code from
pull requests on a public repository. Grant the disk permissions through an IAM
condition scoped to the pool's own resources rather than to the whole project.
Pool disks are named `warm-<pool>-<random>` and snapshots `warm-<pool>-<epoch>`
precisely so that such a condition can be written:

```
resource.name.startsWith("projects/PROJECT/zones/ZONE/disks/warm-")
```

## Example Workflows

* [Test Workflow](./.github/workflows/test.yml): Test workflow.

## Self-hosted runner security with public repositories

From [GitHub's documentation](https://docs.github.com/en/actions/hosting-your-own-runners/about-self-hosted-runners#self-hosted-runner-security-with-public-repositories):

> We recommend that you only use self-hosted runners with private repositories. This is because forks of your
> repository can potentially run dangerous code on your self-hosted runner machine by creating a pull request that
> executes the code in a workflow.

## EC2/AWS action

If you need EC2/AWS self-hosted runner, check out [machulav/ec2-github-runner](https://github.com/machulav/ec2-github-runner).
