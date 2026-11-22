# Working on apple-container-actions-runner

This project runs one trusted GitHub Actions job per Linux ARM64 VM on an Apple silicon Mac. Read the [quickstart](README.md) for the user-facing setup and the [operations guide](OPERATIONS.md) for scheduling, storage, and recovery.

## Where to make changes

- `poll.py` is the host entry point. It holds the installation lock while `poll.sh` reconciles queued jobs, GitHub registrations, and local VMs. Keep host shell code compatible with macOS Bash 3.2 and BSD utilities.
- `api.py` owns authenticated GitHub API calls, pagination, and rate-limit backoff. When inventory is incomplete, skip reconciliation for the affected resources. Treating a failed read as an empty list can remove a working runner.
- `config.py` validates the entire TOML file before provisioning. Use Python 3.11+ and its built-in `tomllib`. For schema changes, update the tracked `runners.toml.example`, the guide, and the test fixtures together. Keep the example disabled and disposable. The operator’s `runners.toml` is gitignored.
- `image/Dockerfile` and `image/entrypoint.sh` run inside the Linux guest. When updating the Actions runner, change the ARM64 archive version and its upstream SHA-256 together. Preserve the shutdown order for nested Docker and trim warm volumes after the daemon stops.

## Isolation and ownership

Scope cleanup to the installation, repository, and slot that own a resource. Preserve the installation ID across passes. Keep the host GitHub credential, poller state, and other jobs’ logs outside the guest. Pass only the single-use JIT configuration for registration and keep it out of logs.

Disposable slots discard job data. Warm slots retain the entire runner home and Docker store across jobs in the same trust boundary. Keep this repository’s pull-request CI on GitHub-hosted macOS. The self-hosted probe belongs in a trusted private scratch repository.

## Verification

From the repository root on macOS, validate the shipped example and run the offline suite:

```sh
python3 config.py --check runners.toml.example
tests/poll_test.sh
```

The suite runs the poller with temporary state and stubbed `gh` and `container` commands. For a focused check, pass case names, for example `tests/poll_test.sh warm_storage foreign_installation`. Add a regression case when changing a scheduling or cleanup decision.

Use the quickstart for live verification. `./build.sh` writes to the local image store, `./install-poller.sh` installs a LaunchAgent, and `./poll.py` can provision real queued work. The end-to-end test, `tests/smoke.py OWNER/PRIVATE-REPO`, dispatches the example workflow and checks that its runner and VM disappear. Report which of the offline suite, local VM, and live GitHub job you actually exercised.
