FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl tar gzip git jq sudo unzip zstd libicu74 liblttng-ust1t64 \
      libkrb5-3 zlib1g libssl3t64 libatomic1 iptables uidmap util-linux procps \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" > /etc/apt/sources.list.d/docker.list \
 && apt-get update && apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
 && rm -rf /var/lib/apt/lists/*
ARG RUNNER_VERSION=2.338.2
ARG RUNNER_SHA256=670adb2f268fe21dcbb58b3db0e0aa9d5b3bddfe2c651481336e561ff86de945

RUN useradd -m -s /bin/bash runner \
 && usermod -aG docker runner \
 && echo "runner ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/runner \
 && chmod 0440 /etc/sudoers.d/runner

# THE RUNNER IS IN /opt, NOT IN /home/runner. A named volume mounts on all of
# /home/runner so that ~/.npm, ~/.cargo, ~/.rustup, ~/.cache and _work stay
# warm between jobs. A new Apple `container` volume is empty and is not seeded
# from the image, so runner binaries below /home/runner would be hidden.
WORKDIR /opt/actions-runner
RUN curl -fsSL -o runner.tar.gz \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-arm64-${RUNNER_VERSION}.tar.gz" \
 && echo "${RUNNER_SHA256}  runner.tar.gz" | sha256sum -c - \
 && tar xzf runner.tar.gz \
 && rm runner.tar.gz \
 && ./bin/installdependencies.sh \
 && chown -R runner:runner /opt/actions-runner /home/runner

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
