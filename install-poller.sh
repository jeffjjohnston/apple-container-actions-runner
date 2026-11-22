#!/bin/bash
#
# Installs the launchd agent that runs poll.sh at the configured interval. Run it again
# after this directory moves or after gh, jq or container move.
#
#   ./install-poller.sh              install or refresh the agent
#   ./install-poller.sh --uninstall  remove the agent
#
# THE AGENT IS A USER AGENT, NOT A DAEMON. poll.sh uses the login keychain and the
# per-user `container` service, and both need a login session. The runners
# therefore come back after a reboot when you log in.
set -euo pipefail

if [ "$(uname -s)" != Darwin ]; then
  echo "This schedule uses macOS launchd." >&2
  exit 1
fi

label=local.apple-container-actions-runner.poller
umask 077
domain="gui/$(id -u)"
agent_dir="$HOME/Library/LaunchAgents"
log_dir="$HOME/Library/Logs/apple-container-actions-runner"
agent="$agent_dir/$label.plist"

remove_agent() {  # <label>
  launchctl bootout "$domain/$1" 2>/dev/null || true
  rm -f "$agent_dir/$1.plist"
}

case "${1:-}" in
  --uninstall) remove_agent "$label"; echo "Removed $label"; exit 0 ;;
  "") ;;
  *) echo "usage: $0 [--uninstall]" >&2; exit 2 ;;
esac

script_dir=$(cd "$(dirname "$0")" && pwd)
path=
for tool in python3 gh jq container; do
  bin=$(command -v "$tool") || { echo "$tool is required" >&2; exit 1; }
  path="$path$(dirname "$bin"):"
done
path="${path}/usr/bin:/bin:/usr/sbin:/sbin"
interval=${POLL_INTERVAL:-30}
case "$interval" in ''|*[!0-9]*) echo "POLL_INTERVAL must be seconds" >&2; exit 1;; esac
[ "$interval" -ge 10 ] || { echo "POLL_INTERVAL must be at least 10" >&2; exit 1; }
python3 "$script_dir/config.py" --check "$script_dir/runners.toml"
mkdir -p "$agent_dir" "$log_dir"

# launchd does not start a second copy while one pass is in operation, so a
# slow pass cannot overlap the next one.
python3 - "$agent" "$label" "$script_dir/poll.py" "$log_dir" "$path" "$interval" <<'PY'
import plistlib
import sys

path, label, script, log_dir, env_path, interval = sys.argv[1:]
job = {
    "Label": label,
    "ProgramArguments": [script],
    "EnvironmentVariables": {"PATH": env_path},
    "StartInterval": int(interval),
    "RunAtLoad": True,
    "StandardOutPath": f"{log_dir}/poller.log",
    "StandardErrorPath": f"{log_dir}/poller.log",
}
with open(path, "wb") as output:
    plistlib.dump(job, output)
PY
plutil -lint "$agent"

launchctl bootout "$domain/$label" 2>/dev/null || true
launchctl bootstrap "$domain" "$agent"
echo "Installed $label: poll.sh at the configured interval"
echo "Log: $log_dir/poller.log"
