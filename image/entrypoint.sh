#!/usr/bin/env bash
# One JIT registration and a private Docker daemon per guest.
set -u

if [ -n "${RUN_LOG:-}" ]; then
  exec > >(tee -a "$RUN_LOG") 2>&1
fi

: "${JIT_CONFIG:?JIT_CONFIG is required; poll.sh supplies it}"


# The config is a credential. Keep it in a shell variable only, so that it is
# not in the environment of dockerd or of the job.
jit=$JIT_CONFIG
unset JIT_CONFIG

exit_code=0
runner_pid=

# THIS CONTAINER RUNS ITS OWN DOCKER DAEMON. The CI jobs declare `services:`
# with `ports: - 5432:5432` and then connect to localhost:5432. That only
# works when the service container and the job share a network namespace,
# which a private daemon gives. It also keeps the image cache and the volumes
# of one runner slot apart from every other slot.
start_docker() {
  # REMOVE THE STALE RUNTIME STATE OF THE DAEMON FIRST. A daemon that finds a
  # pidfile with a PID that is in use decides that a second copy of itself is
  # there, and stops. A new container has an empty /run, so this is only a
  # safeguard for `container start` on a stopped container.
  rm -rf /run/docker.pid /run/docker.sock /run/docker

  if [ -n "${BUILDKIT_GC:-}" ]; then
    mkdir -p /etc/docker
    printf '{"builder":{"gc":{"enabled":true,"defaultKeepStorage":"%s"}}}\n' \
      "$BUILDKIT_GC" > /etc/docker/daemon.json
  fi

  # dockerd must write /proc/sys/net/ipv4/ip_forward. Apple `container` mounts
  # /proc/sys read-only unless the container starts with
  # `--read-only-path NONE`. Without that flag the daemon stops with "failed
  # to set IP forwarding ... read-only file system".
  dockerd --host=unix:///var/run/docker.sock --storage-driver=overlay2 \
    >/var/log/dockerd.log 2>&1 &

  local i
  for i in $(seq 1 60); do
    if docker info >/dev/null 2>&1; then
      echo "dockerd ready after ${i}s"
      return 0
    fi
    sleep 1
  done
  echo "dockerd did not start; last log lines:"
  tail -20 /var/log/dockerd.log
  return 1
}

# A NEW VOLUME BELONGS TO root AND IS EMPTY. The runner then stops with
# "Access to the path '/home/runner/_work/_tool' is denied" before the first
# step runs. Correct the owner here, where this script is still root.
#
# The chown is not recursive. The volume holds gigabytes of caches, and only
# a new volume has the wrong owner, and only at the top.
prepare_home() {
  if [ "$(stat -c %U /home/runner)" != runner ]; then
    echo "preparing new home volume"
    chown runner:runner /home/runner
    sudo -u runner cp -rT /etc/skel /home/runner
  fi
}

# `sudo` drops the environment, so HOME and PATH are passed explicitly.
# The runner removes its own registration after the job; nothing is stored.
run_job() {
  cd /opt/actions-runner || return 1
  sudo -u runner env "HOME=/home/runner" "PATH=$PATH" \
    ./run.sh --jitconfig "$jit" &
  runner_pid=$!
  jit=
  wait "$runner_pid"
  local rc=$?
  # A trapped SIGTERM interrupts `wait`. Wait again for the runner to end.
  if [ "$exit_code" -eq 143 ]; then
    wait "$runner_pid" 2>/dev/null
    return 143
  fi
  return "$rc"
}

on_term() {
  echo "SIGTERM received; stopping the runner"
  exit_code=143
  [ -n "$runner_pid" ] && kill -TERM "$runner_pid" 2>/dev/null
}
trap on_term TERM

# A CLEANUP COMMAND MUST NEVER CHANGE THE RESULT. Each one has a time limit,
# and each error is reported and then ignored.
cleanup() {
  local out
  if out=$(timeout 120 docker "$@" 2>&1); then
    echo "cleanup: docker $*: ${out##*$'\n'}"
  else
    echo "cleanup: docker $* failed, continuing anyway"
    echo "$out"
  fi
}

# WHY THE VOLUME PRUNE EXISTS. A CI job declares `services:` with postgres.
# The postgres image declares VOLUME /var/lib/postgresql/data, so the service
# container gets a new anonymous volume. The runner removes that container
# with `docker rm --force`, which takes no -v, so the volume stays. Each job
# leaks about 550 MB. Measured before this cleanup existed: 99-103 stale
# volumes per runner, 117 GB across three runners, after nine days.
#
# `docker volume prune` removes anonymous volumes only.
cleanup_after_job() {
  cleanup volume prune -f
  cleanup buildx prune --builder default --force --filter until=168h


}

# THE DOCKER CGROUPS MUST BE GONE BEFORE THIS CONTAINER STOPS. While a child
# cgroup of the nested daemon exists, Apple `container` cannot stop the
# container. Measured with container 1.7.1:
#   failed to write to /sys/fs/cgroup/container/<name>/docker/cgroup.kill
# After that error the container accepts no stop, kill or exec; only
# `container rm -f` removes it. So: stop the nested containers, stop the
# daemon, then remove every child cgroup.
shutdown_docker() {
  local ids i
  ids=$(timeout 30 docker ps -q 2>/dev/null)
  # shellcheck disable=SC2086
  [ -n "$ids" ] && timeout 60 docker stop -t 5 $ids >/dev/null 2>&1
  pkill -TERM -x dockerd 2>/dev/null
  for i in $(seq 1 20); do
    pgrep -x dockerd >/dev/null || break
    sleep 1
  done
  pkill -KILL -x dockerd 2>/dev/null
  pkill -KILL -f containerd 2>/dev/null
  find /sys/fs/cgroup -mindepth 1 -depth -type d -exec rmdir {} \; 2>/dev/null
}

# GIVE THE DELETED BLOCKS BACK TO THE MAC. Each volume is a sparse file on the
# host. ext4 does not tell the host which blocks it freed, so without a trim
# the file only grows. Measured: a home volume with 7.8 GB of data held 16 GB
# on the Mac; one fstrim made it 7.9 GB. A trim of all eleven volumes took 4 s.
# This runs after shutdown_docker, so the Docker volume is quiet.
trim_volumes() {
  local dir out
  for dir in /home/runner /var/lib/docker; do
    if out=$(timeout 60 fstrim -v "$dir" 2>&1); then
      echo "cleanup: fstrim $out"
    else
      echo "cleanup: fstrim $dir failed, continuing anyway"
      echo "$out"
    fi
  done
}

if start_docker; then
  prepare_home
  if [ "$exit_code" -eq 0 ]; then
    run_job
    exit_code=$?
    echo "runner exit code: $exit_code"
  fi
  if [ "${STORAGE:-disposable}" = warm ]; then cleanup_after_job; fi
else
  exit_code=1
fi
shutdown_docker
if [ "${STORAGE:-disposable}" = warm ]; then trim_volumes; fi
exit "$exit_code"
