# apple-container-actions-runner

Run trusted GitHub Actions jobs on an Apple silicon Mac. The guest is Ubuntu Linux ARM64. An outbound poller finds queued jobs, asks GitHub for a just-in-time (JIT) runner, and starts one lightweight VM per available slot. GitHub assigns one matching job to each runner. The guest exits after the job and Apple’s `container` removes it. Xcode and Apple SDK builds require a macOS runner.

Each guest runs its own Docker daemon, so workflows can use Docker actions and `services:` with localhost ports. The default slot discards the workspace and Docker data after every job. The Mac retains the runner image, host state, and diagnostic logs.

## Try one job

1. Use an Apple silicon Mac with macOS 26 or later and a logged-in user session that will stay awake. Install Apple’s `container` CLI, GitHub CLI (`gh`), `jq`, and Python 3.11+. Use a stable checkout location. The LaunchAgent runs as the Mac user and starts again after login. The reference host used macOS 27.2.1 and `container` 1.7.1. [Apple installation instructions](https://github.com/apple/container#get-started)

2. Choose a private scratch repository on GitHub.com whose workflows and dependencies you trust. The host credential needs **Actions read** to inspect runs and jobs, and **Administration write** to manage repository JIT runners. Use a dedicated Mac account with a fine-grained token limited to that repository. In Keychain Access, create a password item in that user’s login keychain. Set the item name to `apple-container-actions-runner`, the account to the output of `id -un`, and the password to the token. Test access from a terminal with the command below and grant keychain access when prompted. The poller supplies this credential only to its GitHub CLI calls. [GitHub runner permissions](https://docs.github.com/en/rest/actions/self-hosted-runners)

   ```sh
   security find-generic-password -a "$(id -un)" -s apple-container-actions-runner -w >/dev/null
   ```

3. Copy [examples/probe.yml](examples/probe.yml) to `.github/workflows/probe.yml` on the **default branch of your private scratch repository**. It is a manual workflow that checks guest architecture and reaches an nginx service over localhost. The public example’s own pull-request tests run on GitHub-hosted macOS.

4. Start Apple’s service, build the local image, and copy the disabled example configuration.

   ```sh
   container system start --enable-kernel-install
   ./build.sh
   cp runners.toml.example runners.toml
   ```

   In `runners.toml`, replace `OWNER/PRIVATE-REPO` with the scratch repository and set `enabled = true`. Leave `disposable` selected for the first run. Install the poller and check its host log.

   ```sh
   ./install-poller.sh
   tail -F ~/Library/Logs/apple-container-actions-runner/poller.log
   ```

5. In another terminal, dispatch the probe. Use a separate dispatcher credential with **Actions write** and **Administration read** for the scratch repo. For example, set `GH_TOKEN` in that terminal through your credential manager. Leave the poller’s credential in its keychain. Use a quiet scratch repo so the named slot can fully exit between jobs.

   ```sh
   tests/smoke.py OWNER/PRIVATE-REPO
   ```

   The test prints the URL of its uniquely named run. It checks the job result and assigned runner, then waits for that registration and VM to disappear. Allow up to ten minutes for dispatch and execution, plus four minutes for teardown. Only an identified probe run is eligible for cancellation. For subsequent jobs, use `runs-on: [self-hosted, linux, ARM64, apple-container]`.

## Trust and storage

Use this example for trusted code. A matching job has passwordless sudo and controls the guest daemon. The guest starts with all Linux capabilities and writable kernel settings to support nested Docker. It can reach network services accessible to the guest. Use a dedicated host or network segment appropriate for those jobs. Keep public fork PRs on hosted runners. Labels route jobs, and any eligible workflow in the registered repo can request them. [GitHub self-hosted runner security](https://docs.github.com/en/actions/reference/security/secure-use)

| Storage mode | What survives VM removal |
| --- | --- |
| `disposable` (default example) | The host image, builder cache, diagnostic logs, and poller state. Job files and the guest Docker store are discarded. |
| `warm` (opt-in) | Also keeps **all** of `/home/runner` and `/var/lib/docker` in two named volumes, including workspaces, credentials written by jobs, caches, images, and named Docker volumes. Use only within one trust boundary. |

Each run sees a new writable log directory. The lifecycle markers, installation ID, host credential, and other jobs’ directories stay on the Mac. Treat per-job log contents as job-controlled. The host-managed poller log records scheduling decisions. GitHub retains the workflow step logs.

See [operations](OPERATIONS.md) for scaling, troubleshooting, upgrades, and disk reclamation. Run `tests/poll_test.sh` on macOS to exercise the poller using local stubs. The source is available under the [MIT license](LICENSE).
