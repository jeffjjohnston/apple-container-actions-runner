#!/bin/bash
#
# Builds the runner image with Apple `container`. The tag is the runner
# version from the Dockerfile, which poll.sh reads in the same way.
set -euo pipefail
cd "$(dirname "$0")"

version=$(sed -n 's/^ARG RUNNER_VERSION=//p' image/Dockerfile)
[ -n "$version" ] || { echo "RUNNER_VERSION is not in the Dockerfile" >&2; exit 1; }
tag="apple-container-actions-runner:$version"

container build -t "$tag" image
echo "$tag"
