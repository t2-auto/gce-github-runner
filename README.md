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

### Reservations

`reservation_preference` controls how the runner VM consumes [Compute Engine reservations](https://cloud.google.com/compute/docs/instances/reservations-overview).
It takes a comma separated list of preferences that are tried **in order** until the VM is created:

| Entry | Behaviour |
| --- | --- |
| `any` (default) | Consume any matching automatic reservation in the project, falling back to on-demand capacity when there is none. |
| `none` | Never consume a reservation, always use on-demand capacity. |
| `specific:<name>` | Consume the named reservation only. Fails when it is fully consumed. |

```yaml
# Use the team reservation first, then fall back to on-demand capacity.
reservation_preference: "specific:l4-pool,none"

# Use the team reservation first, then any other automatic reservation, then on-demand.
reservation_preference: "specific:l4-pool,any"

# Strictly stay inside the reservation (fails when it is full).
reservation_preference: "specific:l4-pool"
```

Notes:

* The default `any` matches the `gcloud` default, so leaving this input unset preserves the previous behaviour.
* Before trying a `specific:<name>` entry the action checks the reservation usage and skips it when it is already fully consumed. When the usage cannot be determined (the reservation does not exist, the service account lacks `compute.reservations.get`, ...) the entry is tried anyway so that the real error surfaces from `gcloud`.
* The next entry is only tried when the creation failed because of a **lack of capacity**. Any other failure (invalid machine type, exceeded quota, missing permission, ...) fails immediately instead of being silently retried.
* Reservations whose `specificReservationRequired` is `true` cannot be consumed with `any`; they need an explicit `specific:<name>` entry.

## Example Workflows

* [Test Workflow](./.github/workflows/test.yml): Test workflow.

## Self-hosted runner security with public repositories

From [GitHub's documentation](https://docs.github.com/en/actions/hosting-your-own-runners/about-self-hosted-runners#self-hosted-runner-security-with-public-repositories):

> We recommend that you only use self-hosted runners with private repositories. This is because forks of your
> repository can potentially run dangerous code on your self-hosted runner machine by creating a pull request that
> executes the code in a workflow.

## EC2/AWS action

If you need EC2/AWS self-hosted runner, check out [machulav/ec2-github-runner](https://github.com/machulav/ec2-github-runner).
