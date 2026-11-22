#!/bin/bash
# Single pass under the lock held by poll.py. Requires macOS Bash 3.2.
set -uo pipefail
: "${INSTALLATION:?use poll.py}"
here=$(cd "$(dirname "$0")" && pwd)
conf=${RUNNERS_CONF:-$here/runners.conf}
log_dir=${LOG_DIR:-$HOME/Library/Logs/apple-container-actions-runner}
image=${IMAGE:-apple-container-actions-runner:$(sed -n 's/^ARG RUNNER_VERSION=//p' "$here/image/Dockerfile")}

reap_age=120      # seconds an idle runner can wait before it is stopped
stop_timeout=180  # seconds that `container stop` waits for the entrypoint
offline_age=300   # seconds before a runner that did not connect is removed
stuck_age=900     # seconds a container can be in operation with no registration
base_labels=self-hosted,linux,arm64

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

[ -r "$conf" ] || { log "error cannot read $conf"; exit 1; }
rows=$(python3 "$here/config.py" "$INSTALLATION" "$conf") || exit 1
[ -n "$rows" ] || exit 0
mkdir -p "$log_dir/jobs" || exit 1
enabled_slots() { printf '%s\n' "$rows"; }
api() { python3 "$here/api.py" "$@"; }

# The service does not start at boot by itself. Start it here, so that the
# runners come back after a reboot with no manual step.
ensure_service() {
  if ! container system status 2>/dev/null | grep -Eq '^status[[:space:]]+running'; then
    log "service not in operation; starting it"
    container system start --enable-kernel-install >/dev/null 2>&1 \
      || log "error container system start failed"
  fi
}

# container_field <name> <state|age>: empty state means that no such
# container exists.
container_field() {
  local started
  case "$2" in
    state)
      printf '%s' "$containers" | jq -r --arg n "$1" \
        '.[] | select(.id == $n) | (.status.state? // .status // "unknown")' ;;
    age)
      started=$(printf '%s' "$containers" | jq -r --arg n "$1" \
        '.[] | select(.id == $n) | (.status.startedDate? // .configuration.creationDate // "")')
      started=$(date -j -u -f %Y-%m-%dT%H:%M:%SZ "$started" +%s 2>/dev/null) || started=$now
      echo $(( now - started )) ;;
  esac
}

# runner_field <name> <id|busy>: empty means that no such runner is registered.
runner_field() {
  printf '%s' "$runners" | jq -r --arg n "$1" --arg f "$2" \
    '.runners[] | select(.name == $n) | .[$f]'
}

delete_runner() {  # <repo> <runner id>
  api DELETE "repos/$1/actions/runners/$2" >/dev/null
}

# Print the number of queued jobs that a slot of this repository can take. A
# job counts only if each of its labels is in the label set of the slots, so a
# job for a hosted runner in the same repository starts nothing. GitHub
# compares labels without regard to case, and so does this function.
#
# A failed API call gives a non-zero exit code. The caller must then do
# nothing for the repository: an error is not the same as "zero jobs".
count_queued() {  # <repo> <label set>
  local status runs more ids= id jobs n total=0
  # A run that is in_progress can also contain queued jobs. The status filter
  # keeps the responses small, and it finds an old run that was started again,
  # which is not in the newest 100 runs.
  for status in queued in_progress; do
    runs=$(api GET "repos/$1/actions/runs?status=$status&per_page=100" workflow_runs) || return 1
    more=$(printf '%s' "$runs" \
      | jq -r '.workflow_runs[] | select(.status != "completed") | .id') || return 1
    ids="$ids $more"
  done
  # A run can change status between the two calls and be in both lists.
  for id in $(printf '%s\n' $ids | sort -u); do
    jobs=$(api GET "repos/$1/actions/runs/$id/jobs?per_page=100" jobs) || return 1
    n=$(printf '%s' "$jobs" | jq --arg set "$2" '
      ($set | ascii_downcase | split(",")) as $s
      | [.jobs[] | select(.status == "queued" and (.labels | type == "array" and length > 0))
         | select(all(.labels[]; ascii_downcase | IN($s[])))] | length') || return 1
    total=$(( total + n ))
  done
  echo "$total"
}

# Get a JIT config for one runner. On success, set jit and jit_runner_id.
get_jit() {
  local resp
  resp=$(jq -nc --arg name "$2" --arg labels "self-hosted,ARM64,linux,$3" \
    '{name: $name, runner_group_id: 1, work_folder: "/home/runner/_work", labels: ($labels | split(","))}' \
    | api POST "repos/$1/actions/runners/generate-jitconfig") || return 1
  jit=$(printf '%s' "$resp" | jq -er '.encoded_jit_config | strings | select(length > 0)') || return 1
  jit_runner_id=$(printf '%s' "$resp" | jq -er '.runner.id | numbers')
}

start_slot() {
  local slot=$1 repo=$2 v job_dir volumes
  local -a mounts
  mounts=()
  if [ "$7" = warm ]; then
    volumes=$(container volume ls -q) || return 1
    for v in "$slot-docker" "$slot-home"; do
      if ! grep -Fxq "$v" <<< "$volumes"; then
        container volume create "$v" >/dev/null || return 1
      fi
    done
    mounts=(-v "$slot-docker:/var/lib/docker" -v "$slot-home:/home/runner")
  fi
  job_dir=$(mktemp -d "$log_dir/jobs/gh-$slot.XXXXXXXX") || return 1
  local jit= jit_runner_id=
  get_jit "$repo" "gh-$slot" "$3" || { rmdir "$job_dir"; log "error $slot: cannot get a JIT config"; return 1; }

  # THE JIT CONFIG GOES THROUGH THE ENVIRONMENT OF THIS ONE COMMAND. `-e
  # JIT_CONFIG` with no value tells `container` to copy the variable, so the
  # config is not in an argument list or a log. `container` keeps the
  # environment in its config file for the container until the container is
  # removed. The config is of no use after the runner took its one job.
  if JIT_CONFIG=$jit container run -d --rm --name "gh-$slot" \
      --cap-add ALL --read-only-path NONE -c "$4" -m "$5" \
      ${mounts[@]+"${mounts[@]}"} -v "$job_dir:/var/log/gh-runner" \
      -e JIT_CONFIG -e "STORAGE=$7" -e "BUILDKIT_GC=$6" \
      -e RUN_LOG=/var/log/gh-runner/runner.log \
      --progress none "$image" >/dev/null 2>&1; then
    log "start $slot"
  else
    # Without this, each pass that fails would leave one more registration.
    delete_runner "$repo" "$jit_runner_id"
    log "error $slot: container run failed"
    return 1
  fi
}

poll_repo() {  # <repo>
  local repo=$1 lines labels queued
  lines=$(enabled_slots | awk -F'|' -v r="$repo" '$2 == r')
  IFS='|' read -r _ _ labels _ <<< "$lines"
  labels="$base_labels,$labels"

  queued=$(count_queued "$repo" "$labels") \
    || { log "error $repo: cannot read the queued jobs; nothing done"; return; }

  # The usual pass ends here after two API calls: no job and no container.
  local slot rest any=no
  while IFS='|' read -r slot rest; do
    [ -n "$(container_field "gh-$slot" state)" ] && any=yes
  done <<< "$lines"
  [ "$queued" -eq 0 ] && [ "$any" = no ] && return

  local runners
  runners=$(api GET "repos/$repo/actions/runners?per_page=100" runners) \
    || { log "error $repo: cannot read the runners; nothing done"; return; }

  local r l cpus mem gc en storage name state id busy age marker seen idle=0 free=
  while IFS='|' read -r slot r l cpus mem gc en storage; do
    name="gh-$slot"
    marker="$STATE_DIR/.unregistered-$name"
    state=$(container_field "$name" state)
    id=$(runner_field "$name" id)
    busy=$(runner_field "$name" busy)

    if [ -n "$state" ] && [ "$state" != running ]; then
      # A container that is listed but not in operation. The usual cause is a
      # stop that failed on the Docker cgroups (see entrypoint.sh); such a
      # container accepts only `rm -f`.
      container rm -f "$name" >/dev/null || continue
      log "remove $slot (state $state)"
      state=
    fi

    if [ -z "$state" ]; then
      # A registration with no container cannot take a job. If it stayed, it
      # would count as an idle runner and prevent the start of a real one.
      if [ -n "$id" ]; then
        [ "$busy" = false ] && delete_runner "$repo" "$id" || continue
      fi
      rm -f "$marker"
      free="$free$slot|$r|$l|$cpus|$mem|$gc|$storage"$'\n'
      continue
    fi

    age=$(container_field "$name" age)
    if [ -z "$id" ]; then
      # No registration: a new container that did not connect yet, or an old
      # one that completed its job and now does its cleanup. Only the first
      # will take a job. The second must not be stopped.
      #
      # The age of the container does not show how long the cleanup has run,
      # because the job can be long. The marker file records the first pass
      # that found this condition. A container that stays in it for longer
      # than the cleanup can take will never end by itself.
      [ -e "$marker" ] || touch "$marker"
      seen=$(( now - $(stat -f %m "$marker" 2>/dev/null || echo "$now") ))
      if [ "$seen" -gt "$stuck_age" ]; then
        container rm -f "$name" >/dev/null || continue
        rm -f "$marker"
        log "remove $slot (no registration for ${seen}s)"
        continue
      fi
      [ "$age" -le "$reap_age" ] && idle=$(( idle + 1 ))
      continue
    fi
    rm -f "$marker"

    [ "$busy" = false ] || continue
    # FOR BOTH CASES BELOW, DELETE THE REGISTRATION FIRST. GitHub can give a
    # job to this runner at any moment. A deleted registration cannot get a
    # job, and GitHub refuses to delete a runner that has one. Thus a runner
    # with a job is never stopped.
    if [ "$(runner_field "$name" status)" = offline ] && [ "$age" -gt "$offline_age" ]; then
      # The runner did not connect, so it will not take a job. If it stayed,
      # it would count as idle and a queued job would wait with no runner.
      if delete_runner "$repo" "$id"; then
        container rm -f "$name" >/dev/null || continue
        log "remove $slot (runner offline, container age ${age}s)"
      else
        log "error $slot: cannot delete the registration of the offline runner"
      fi
    elif [ "$queued" -eq 0 ] && [ "$age" -gt "$reap_age" ]; then
      # The job that this runner was started for is gone, usually because
      # it was cancelled. Do not let the VM hold its memory.
      if delete_runner "$repo" "$id"; then
        log "reap $slot (idle for ${age}s)"
        container stop -t "$stop_timeout" "$name" >/dev/null 2>&1 \
          || log "error $slot: container stop failed"
      else
        log "error $slot: cannot delete the registration; runner not stopped"
      fi
    else
      idle=$(( idle + 1 ))
    fi
  done <<< "$lines"

  local need=$(( queued - idle ))
  while IFS='|' read -r slot r l cpus mem gc storage; do
    [ -n "$slot" ] && [ "$need" -gt 0 ] || continue
    start_slot "$slot" "$r" "$l" "$cpus" "$mem" "$gc" "$storage" || continue
    need=$(( need - 1 ))
  done <<< "$free"
}

ensure_service
now=$(date +%s)
# A failed list is not the same as "no containers". With an empty list, the
# poller would delete the registration of each runner that is alive.
containers=$(container ls -a --format json 2>/dev/null) && jq -se 'length == 1 and (.[0] | type == "array" and all(.[]; (.id | type) == "string" and ((.status.state? // .status) | type) == "string"))' >/dev/null <<< "$containers" \
  || { log "error cannot list the containers; nothing done"; exit 0; }

for repo in $(enabled_slots | cut -d'|' -f2 | awk '!seen[$0]++'); do
  poll_repo "$repo"
done

# Only visit immediate entries under the host-owned parent.
find "$log_dir/jobs" -mindepth 1 -maxdepth 1 -type d -name 'gh-*' -mtime +14 -exec rm -rf {} +
exit 0
