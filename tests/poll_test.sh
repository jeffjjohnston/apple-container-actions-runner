#!/bin/bash
#
# Tests for poll.sh. `gh` and `container` are stubs (tests/stubs) that record
# each call and answer from a fixture directory. The JSON field names in the
# fixtures come from real output of container 1.7.1 and of the GitHub API.
#
# usage: tests/poll_test.sh [case-name ...]
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
export PATH="$here/tests/stubs:$PATH"
passed=0

setup() {
  tmp=$(mktemp -d)
  export FIXTURE_DIR="$tmp/fx" CALLS_LOG="$tmp/calls" LOG_DIR="$tmp/logs" \
    RUNNERS_CONF="$tmp/runners.conf" IMAGE=gh-runner-arm64:test
  export GH_TOKEN=test-only STATE_DIR="$tmp/state"
  mkdir -p "$FIXTURE_DIR" "$LOG_DIR/jobs" "$STATE_DIR"
  printf 0123456789abcdef > "$STATE_DIR/installation"
  : > "$CALLS_LOG"
  echo 'test-1|o/test|dind|8|4G||yes|disposable' > "$RUNNERS_CONF"
  echo '{"runner":{"id":77,"name":"gh-0123456789abcdef-a4fdc28e4580-test-1"},"encoded_jit_config":"FAKEJIT"}' > "$FIXTURE_DIR/gh-jit.json"
  runs; runners
}

# runs [id ...]: the listed runs are not completed.
runs() {
  local out= id
  for id in "$@"; do out="$out{\"id\":$id,\"status\":\"queued\"},"; done
  echo "{\"workflow_runs\":[{\"id\":900,\"status\":\"completed\"},${out%,}]}" | sed 's/,]/]/' > "$FIXTURE_DIR/gh-runs.json"
}
# jobs <labels-csv> ...: one queued job for each argument.
jobs() {
  local out= l
  for l in "$@"; do
    out="$out{\"status\":\"queued\",\"labels\":$(printf '%s' "$l" | jq -Rc 'split(",")')},"
  done
  echo "{\"jobs\":[{\"status\":\"completed\",\"labels\":[\"self-hosted\",\"dind\"]},${out%,}]}" | sed 's/,]/]/' > "$FIXTURE_DIR/gh-jobs.json"
}
# runners <id:name:busy[:status]> ...
runners() {
  local out= r id name busy status
  for r in "$@"; do
    IFS=: read -r id name busy status <<< "$r"
    out="$out{\"id\":$id,\"name\":\"$name\",\"status\":\"${status:-online}\",\"busy\":$busy},"
  done
  echo "{\"total_count\":$#,\"runners\":[${out%,}]}" > "${RUNNERS_FILE:-$FIXTURE_DIR/gh-runners.json}"
}
# containers <name:state:age-seconds> ...
containers() {
  local out= c
  for c in "$@"; do
    IFS=: read -r name state age <<< "$c"
    out="$out{\"id\":\"$name\",\"configuration\":{\"id\":\"$name\"},\"status\":{\"state\":\"$state\",\"startedDate\":\"$(date -u -v-"${age}"S +%Y-%m-%dT%H:%M:%SZ)\"}},"
  done
  echo "[${out%,}]" > "$FIXTURE_DIR/container-ls.json"
}

run_poll() { out=$("$here/poll.py" 2>&1); rc=$?; }

fail() {
  echo "FAIL $case_name: $*"
  echo "--- calls"; cat "$CALLS_LOG"; echo "--- output"; echo "$out"
  exit 1
}
called()     { grep -qE -- "$1" "$CALLS_LOG" || fail "expected a call that matches: $1"; }
not_called() { grep -qE -- "$1" "$CALLS_LOG" && fail "unexpected call that matches: $1"; return 0; }
count()      { local n; n=$(grep -cE -- "$1" "$CALLS_LOG"); [ "$n" -eq "$2" ] || fail "expected $2 calls that match '$1', got $n"; }
output()     { echo "$out" | grep -qE -- "$1" || fail "expected output that matches: $1"; }
# before <a> <b>: the first call that matches a is earlier than the first that matches b.
before() {
  local a b
  a=$(grep -nE -- "$1" "$CALLS_LOG" | head -1 | cut -d: -f1)
  b=$(grep -nE -- "$2" "$CALLS_LOG" | head -1 | cut -d: -f1)
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] || fail "expected '$1' before '$2'"
}

idle_no_jobs() {
  run_poll
  [ "$rc" -eq 0 ] || fail "exit code $rc"
  not_called 'container run'; not_called 'generate-jitconfig'
  # One call for each run status, and no other call.
  count '^gh ' 2
  called 'runs\?status=queued'
  called 'runs\?status=in_progress'
}
in_progress_run() {
  # The run is in the second list only: it is in progress, and one of its
  # jobs waits for a runner.
  echo '{"workflow_runs":[]}' > "$FIXTURE_DIR/gh-runs.1.json"
  echo '{"workflow_runs":[{"id":7,"status":"in_progress"}]}' > "$FIXTURE_DIR/gh-runs.2.json"
  jobs self-hosted,dind
  run_poll
  called 'runs/7/jobs'
  count 'container run' 1
}
run_in_both_lists() {
  # A run can change from queued to in_progress between the two calls.
  runs 1; jobs self-hosted,dind
  run_poll
  count 'runs/1/jobs' 1
  count 'container run' 1
}
one_job_starts_slot() {
  runs 1; jobs self-hosted,ARM64,linux,dind
  run_poll
  count 'container run' 1
  called 'container run .*--name gh-0123456789abcdef-a4fdc28e4580-test-1'
  called 'container run .*--rm'
  called 'container run .*--cap-add ALL'
  called 'container run .*--read-only-path NONE'
  called 'container run .*-c 8 .*-m 4G'
  not_called 'container volume create'
  not_called ':/var/lib/docker|:/home/runner'
  called 'container run .*STORAGE=disposable'
  called "container run .*$LOG_DIR/jobs/gh-.*:/var/log/gh-runner"
  not_called "$STATE_DIR:|$LOG_DIR:"
  [ "$(cat "$FIXTURE_DIR/.jit-seen")" = FAKEJIT ] || fail "the container did not receive the JIT config"
  output 'start 0123456789abcdef-a4fdc28e4580-test-1'
}
jit_not_in_output() {
  runs 1; jobs self-hosted,dind
  run_poll
  count 'container run' 1
  grep -q FAKEJIT "$CALLS_LOG" && fail "the JIT config is in an argument list"
  echo "$out" | grep -q FAKEJIT && fail "the JIT config is in the output"
  grep -rq FAKEJIT "$LOG_DIR" && fail "the JIT config is in a log file"
  return 0
}
two_jobs_one_slot() {
  runs 1; jobs self-hosted,dind self-hosted,dind
  run_poll
  count 'container run' 1
}
runner_already_idle() {
  runs 1; jobs self-hosted,dind
  containers gh-0123456789abcdef-a4fdc28e4580-test-1:running:10; runners 5:gh-0123456789abcdef-a4fdc28e4580-test-1:false
  run_poll
  not_called 'container run'; not_called 'container stop'; not_called 'DELETE'
}
busy_runner_not_idle() {
  printf '%s\n' 'test-1|o/test|dind|8|4G||yes|disposable' 'test-2|o/test|dind|8|4G||yes|disposable' > "$RUNNERS_CONF"
  runs 1; jobs self-hosted,dind
  containers gh-0123456789abcdef-a4fdc28e4580-test-1:running:400; runners 5:gh-0123456789abcdef-a4fdc28e4580-test-1:true
  run_poll
  count 'container run' 1
  called 'container run .*--name gh-0123456789abcdef-a4fdc28e4580-test-2'
}
hosted_job_ignored() {
  runs 1; jobs ubuntu-latest
  run_poll
  not_called 'container run'; not_called 'generate-jitconfig'
}
label_case() {
  runs 1; jobs self-hosted,Linux,arm64,DIND
  run_poll
  count 'container run' 1
}
extra_label_ignored() {
  runs 1; jobs self-hosted,dind,gpu
  run_poll
  not_called 'container run'
}
disabled_slot() {
  printf '%s\n' '# comment' '' 'off-1|o/off|dind|8|4G||no|disposable' 'test-1|o/test|dind|8|4G||yes|disposable' > "$RUNNERS_CONF"
  runs 1; jobs self-hosted,dind
  run_poll
  not_called 'o/off'
  count 'container run' 1
}
api_error() {
  echo 1 > "$FIXTURE_DIR/gh-runs.exit"
  containers gh-0123456789abcdef-a4fdc28e4580-test-1:running:300; runners 5:gh-0123456789abcdef-a4fdc28e4580-test-1:false
  run_poll
  [ "$rc" -eq 0 ] || fail "exit code $rc"
  not_called 'container run'; not_called 'container stop'; not_called 'DELETE'
  output 'error o/test'
}
jobs_api_error() {
  runs 1; echo 1 > "$FIXTURE_DIR/gh-jobs.exit"
  containers gh-0123456789abcdef-a4fdc28e4580-test-1:running:300; runners 5:gh-0123456789abcdef-a4fdc28e4580-test-1:false
  run_poll
  not_called 'container run'; not_called 'container stop'
  output 'error o/test'
}
orphan_registration() {
  runs 1; jobs self-hosted,dind
  runners 5:gh-0123456789abcdef-a4fdc28e4580-test-1:false
  run_poll
  called '-X DELETE repos/o/test/actions/runners/5$'
  count 'container run' 1
  before 'DELETE' 'container run'
}
jit_409() {
  runs 1; jobs self-hosted,dind
  echo 1 > "$FIXTURE_DIR/gh-jit.1.exit"
  echo 'gh: Already exists - A runner with the name gh-0123456789abcdef-a4fdc28e4580-test-1 already exists. (HTTP 409)' > "$FIXTURE_DIR/gh-jit.1.err"
  RUNNERS_FILE="$FIXTURE_DIR/gh-runners.2.json" runners 9:gh-0123456789abcdef-a4fdc28e4580-test-1:false
  run_poll
  not_called 'DELETE'
  count 'generate-jitconfig' 1
  not_called 'container run'

}
jit_other_error() {
  runs 1; jobs self-hosted,dind
  echo 1 > "$FIXTURE_DIR/gh-jit.exit"
  echo 'gh: Forbidden (HTTP 403)' > "$FIXTURE_DIR/gh-jit.err"
  run_poll
  count 'generate-jitconfig' 1
  not_called 'container run'
  output 'error 0123456789abcdef-a4fdc28e4580-test-1'
}
run_fails() {
  runs 1; jobs self-hosted,dind
  echo 1 > "$FIXTURE_DIR/container-run.exit"
  run_poll
  called '-X DELETE repos/o/test/actions/runners/77$'
  output 'error 0123456789abcdef-a4fdc28e4580-test-1'
}
stuck_container() {
  runs 1; jobs self-hosted,dind
  containers gh-0123456789abcdef-a4fdc28e4580-test-1:stopped:500
  run_poll
  called 'container rm -f gh-0123456789abcdef-a4fdc28e4580-test-1'
  count 'container run' 1
  before 'container rm -f gh-0123456789abcdef-a4fdc28e4580-test-1' 'container run'
  output 'remove 0123456789abcdef-a4fdc28e4580-test-1'
}
reap_idle() {
  containers gh-0123456789abcdef-a4fdc28e4580-test-1:running:300; runners 5:gh-0123456789abcdef-a4fdc28e4580-test-1:false
  run_poll
  called 'container stop .*gh-0123456789abcdef-a4fdc28e4580-test-1'
  called 'container stop .*(-t|--time) 180'
  # A deleted registration cannot get a job, so the delete comes first.
  called '-X DELETE repos/o/test/actions/runners/5$'
  before 'DELETE' 'container stop'
  output 'reap 0123456789abcdef-a4fdc28e4580-test-1'
}
reap_delete_refused() {
  # GitHub refuses to delete a runner that got a job a moment ago.
  echo 1 > "$FIXTURE_DIR/gh-delete.exit"
  containers gh-0123456789abcdef-a4fdc28e4580-test-1:running:300; runners 5:gh-0123456789abcdef-a4fdc28e4580-test-1:false
  run_poll
  not_called 'container stop'; not_called 'container rm'
  output 'error 0123456789abcdef-a4fdc28e4580-test-1'
}
container_ls_fails() {
  # An error is not the same as "no containers": the registration of a
  # runner that is alive must stay.
  echo 1 > "$FIXTURE_DIR/container-ls.exit"
  runs 1; jobs self-hosted,dind
  runners 5:gh-0123456789abcdef-a4fdc28e4580-test-1:false
  run_poll
  [ "$rc" -eq 0 ] || fail "exit code $rc"
  not_called '^gh '; not_called 'container run'
  output 'error'
}
offline_runner_removed() {
  runs 1; jobs self-hosted,dind
  containers gh-0123456789abcdef-a4fdc28e4580-test-1:running:400; runners 5:gh-0123456789abcdef-a4fdc28e4580-test-1:false:offline
  run_poll
  called '-X DELETE repos/o/test/actions/runners/5$'
  called 'container rm -f gh-0123456789abcdef-a4fdc28e4580-test-1'
  before 'DELETE' 'container rm -f'
  output 'remove 0123456789abcdef-a4fdc28e4580-test-1'
}
offline_young_kept() {
  # A new runner is offline until it connects.
  runs 1; jobs self-hosted,dind
  containers gh-0123456789abcdef-a4fdc28e4580-test-1:running:60; runners 5:gh-0123456789abcdef-a4fdc28e4580-test-1:false:offline
  run_poll
  not_called 'DELETE'; not_called 'container rm'; not_called 'container run'
}
unregistered_first_seen() {
  containers gh-0123456789abcdef-a4fdc28e4580-test-1:running:2000
  run_poll
  not_called 'container rm'; not_called 'container stop'
  [ -e "$STATE_DIR/.unregistered-gh-0123456789abcdef-a4fdc28e4580-test-1" ] || fail "no marker file"
}
unregistered_stuck_removed() {
  containers gh-0123456789abcdef-a4fdc28e4580-test-1:running:2000
  touch -t "$(date -v-1000S +%Y%m%d%H%M.%S)" "$STATE_DIR/.unregistered-gh-0123456789abcdef-a4fdc28e4580-test-1"
  run_poll
  called 'container rm -f gh-0123456789abcdef-a4fdc28e4580-test-1'
  output 'remove 0123456789abcdef-a4fdc28e4580-test-1'
  [ ! -e "$STATE_DIR/.unregistered-gh-0123456789abcdef-a4fdc28e4580-test-1" ] || fail "the marker file stayed"
}
marker_cleared() {
  runs 1; jobs self-hosted,dind
  containers gh-0123456789abcdef-a4fdc28e4580-test-1:running:30; runners 5:gh-0123456789abcdef-a4fdc28e4580-test-1:false
  touch -t "$(date -v-1000S +%Y%m%d%H%M.%S)" "$STATE_DIR/.unregistered-gh-0123456789abcdef-a4fdc28e4580-test-1"
  run_poll
  not_called 'container rm'
  [ ! -e "$STATE_DIR/.unregistered-gh-0123456789abcdef-a4fdc28e4580-test-1" ] || fail "the marker file stayed"
}
no_reap_young() {
  containers gh-0123456789abcdef-a4fdc28e4580-test-1:running:30; runners 5:gh-0123456789abcdef-a4fdc28e4580-test-1:false
  run_poll
  not_called 'container stop'
}
no_reap_busy() {
  containers gh-0123456789abcdef-a4fdc28e4580-test-1:running:300; runners 5:gh-0123456789abcdef-a4fdc28e4580-test-1:true
  run_poll
  not_called 'container stop'
}
no_reap_after_job() {
  # No registration and an old container: the job is done and the entrypoint
  # does its cleanup. A stop here would only interrupt that cleanup.
  containers gh-0123456789abcdef-a4fdc28e4580-test-1:running:300
  run_poll
  not_called 'container stop'
}
other_container_untouched() {
  runs 1; jobs self-hosted,dind
  containers buildkit:running:9000 gh-other-1:stopped:9000
  run_poll
  not_called 'container rm'; not_called 'container stop'
  count 'container run' 1
}
service_down() {
  echo 'apiserver is not running and not registered with launchd' > "$FIXTURE_DIR/container-status.txt"
  run_poll
  called 'container system start --enable-kernel-install'
  before 'container system start' 'container ls'
}
old_logs_deleted() {
  mkdir "$LOG_DIR/jobs/gh-old" "$LOG_DIR/jobs/gh-recent"
  touch -t "$(date -v-15d +%Y%m%d%H%M)" "$LOG_DIR/jobs/gh-old"
  touch -t "$(date -v-1d +%Y%m%d%H%M)" "$LOG_DIR/jobs/gh-recent"
  touch -t "$(date -v-15d +%Y%m%d%H%M)" "$LOG_DIR/poller.log"
  run_poll
  [ ! -e "$LOG_DIR/jobs/gh-old" ] || fail "gh-a.log was not deleted"
  [ -e "$LOG_DIR/jobs/gh-recent" ] || fail "gh-b.log was deleted"
  [ -e "$LOG_DIR/poller.log" ] || fail "poller.log was deleted"
}
missing_config() {
  rm "$RUNNERS_CONF"
  run_poll
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit code"
  not_called 'container run'
}

warm_storage() {
  sed -i '' 's/disposable/warm/' "$RUNNERS_CONF"
  runs 1; jobs dind
  run_poll
  called 'volume create .*test-1-docker'
  called 'container run .*test-1-home:/home/runner'
}
bad_config() {
  echo 'other|o/test|gpu|2|4G||yes|warm' >> "$RUNNERS_CONF"
  run_poll
  [ "$rc" -ne 0 ] || fail "accepted mixed labels"
  not_called '^gh |^container '
}
malformed_inventory() {
  echo '{}' > "$FIXTURE_DIR/container-ls.json"
  run_poll
  not_called '^gh '
}
next_page() {
  echo 'Link: <url>; rel="next"' > "$FIXTURE_DIR/gh-runs.1.headers"
  echo '{"workflow_runs":[]}' > "$FIXTURE_DIR/gh-runs.1.json"
  runs 1; jobs dind
  run_poll
  called 'status=queued.*page=2'
  called 'container run'
}
rate_limited() {
  echo 1 > "$FIXTURE_DIR/gh-runs.exit"
  echo 'Retry-After: 90' > "$FIXTURE_DIR/gh-runs.headers"
  run_poll
  [ "$(cat "$STATE_DIR/retry-at")" -gt "$(date +%s)" ] || fail "missing backoff"
  run_poll
  count '^gh ' 1
}
foreign_installation() {
  runs 1; jobs dind
  runners 10:gh-2222222222222222-other-test-1:false
  containers gh-2222222222222222-other-test-1:stopped:500
  run_poll
  not_called 'DELETE|container rm'
  count 'container run' 1
}
empty_inventory() {
  : > "$FIXTURE_DIR/container-ls.json"
  run_poll
  not_called '^gh '
}
all_disabled() {
  cp "$here/runners.conf.example" "$RUNNERS_CONF"
  run_poll
  [ "$rc" -eq 0 ] || fail "disabled configuration failed"
  not_called '^gh |^container '
}
all="foreign_installation empty_inventory all_disabled warm_storage bad_config malformed_inventory next_page rate_limited idle_no_jobs in_progress_run run_in_both_lists reap_delete_refused
container_ls_fails offline_runner_removed offline_young_kept
unregistered_first_seen unregistered_stuck_removed marker_cleared one_job_starts_slot jit_not_in_output two_jobs_one_slot
runner_already_idle busy_runner_not_idle hosted_job_ignored label_case
extra_label_ignored disabled_slot api_error jobs_api_error orphan_registration
jit_409 jit_other_error run_fails stuck_container reap_idle no_reap_young
no_reap_busy no_reap_after_job other_container_untouched service_down
old_logs_deleted missing_config"

for case_name in ${*:-$all}; do
  setup
  "$case_name"
  rm -rf "$tmp"
  passed=$((passed + 1))
  echo "ok   $case_name"
done
echo "PASS: $passed cases"
