# Operating the runner

## Slots and scheduling

Each `[[runners]]` table in `runners.toml` defines one concurrent VM. To add another slot, copy the table and give it a unique lowercase name. This example retains a trusted slot’s workspace and Docker data between jobs.

```toml
[[runners]]
name = "linux-2"
repository = "example/private-ci"
labels = ["apple-container"]
enabled = true

cpus = 2
memory = "4G"
storage = "warm"
buildkit_gc = "2GB"
```

Enabled slots in a repository must share the same additional labels. The poller adds `self-hosted,linux,ARM64` and compares labels case-insensitively. Use a positive integer for CPUs and `M` or `G` for memory. The optional `buildkit_gc` target accepts `MB` or `GB` and covers only build cache. The complete file is validated on each pass.

The name of each registration and VM is `gh-<installation>-<repo-hash>-<slot>`. Each Mac account generates its own installation ID under `~/Library/Application Support/apple-container-actions-runner`. Keep the ID on that machine. Repository or slot renames create a new namespace. The installer manages one poller per Mac account. A host-side lock serializes manual and scheduled passes.

At the default 30-second interval an idle repo costs about 240 REST requests/hour. Active runs add job and runner lookups. The poller follows pagination, skips reconciliation on failed inventory reads, and records GitHub rate-limit deadlines in host state. A JIT runner can pick up any matching job. The number of slots bounds concurrency. To change the polling interval, reinstall with e.g. `POLL_INTERVAL=60 ./install-poller.sh`. [GitHub API limits](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api)

## A job stays queued

1. Check that the Mac is awake and the user is logged in. Inspect `launchctl print "gui/$(id -u)/local.apple-container-actions-runner.poller"`, `container system status`, and `container ls -a`.
2. Check the configured repository and every requested label. Confirm the image tag from `./build.sh` appears in `container image ls`. The installer records executable paths, so reinstall after moving the checkout or tools.
3. Read `~/Library/Logs/apple-container-actions-runner/poller.log` for API errors, rate limiting, launch failures, and reaping. A quiet idle pass is normal. Check `jobs/gh-*/runner.log` in the same log directory for guest startup and shutdown output. Check the Actions run for step output. The poller prunes job directories older than 14 days during enabled passes. Manage or rotate the host poller log separately.
4. Repeat the login keychain access check in the quickstart as the LaunchAgent user. Run `./poll.py` for a normal foreground pass. This can provision runners for real queued jobs. Use `tests/poll_test.sh` for offline testing.

## Drain, upgrade, and reclaim disk

Pause dispatches for the affected workflows. Allow running jobs to finish and leave the slot enabled until its VM has exited. An idle runner left after a cancellation is normally reaped after about two minutes. Confirm with `container ls -a`, then set `enabled = false`. Disabled slots are skipped. To uninstall the schedule, run `./install-poller.sh --uninstall`. The image, logs, installation ID, and any warm volumes remain.

For a runner update, change the version and corresponding upstream Linux ARM64 SHA-256 in `image/Dockerfile`, rebuild, and run the private probe. The next VM uses the versioned tag. Rebuild regularly for base image and Docker updates. The build can leave Apple’s shared builder VM running. Use `container builder status` and stop it with `container builder stop` when other builds have finished. [Runner releases](https://github.com/actions/runner/releases)

For warm slots, the entrypoint prunes unused anonymous Docker volumes and old build cache, stops nested containers and Docker, removes nested cgroups, then trims both mounted filesystems. This order matters on Apple container 1.7.1. BuildKit GC cannot limit the total size of the runner home, Docker images, or named volumes. After draining a slot, list its exact volumes with `container volume ls`. To permanently discard its warm data, use `container volume rm <slot-prefix>-docker <slot-prefix>-home`, substituting the actual names. The poller recreates them on the next warm start.

## Sizing observations

The original 18-core, 48 GiB Apple silicon host measured 21–23 seconds from dispatch to job start with a 15-second poll and a prebuilt image. An integration suite timed out at 4 GiB under direct memory reclaim and completed its HTTP step in 68 seconds at 8 GiB. These measurements came from the original deployment. Size slots for your own concurrency, cold image pulls, and peak working set. Service containers share the VM’s CPU and memory.
