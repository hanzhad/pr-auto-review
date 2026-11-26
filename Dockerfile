# Dockerfile for auto-review machine container (Issue 207 / 4.1).
#
# Dedicated, persistent machine container for pull request inspection.
# The gate runs as unprivileged user 'reviewer' (uid 10001); the entrypoint starts
# as uid 0 and drops to it at once, keeping only CAP_SETUID/CAP_SETGID. Each review
# runs as 'rv' (uid 10002), no capabilities, no home in the image.
# Has NO access to Docker daemon socket (/var/run/docker.sock) and NO host mounts.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Core utilities and CLI tools
RUN apt-get update && apt-get install --yes --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    git \
    gnupg \
    jq \
    procps \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 22 LTS (needed for @anthropic-ai/claude-code)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install --yes --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*

# Install GitHub CLI (gh)
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | \
      dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | \
      tee /etc/apt/sources.list.d/github-cli.list > /dev/null && \
    apt-get update && apt-get install --yes --no-install-recommends gh && \
    rm -rf /var/lib/apt/lists/*

# Install Agent CLI harnesses (Claude Code and Antigravity CLI)
RUN npm install -g @anthropic-ai/claude-code
RUN curl -fsSL https://antigravity.google/cli/install.sh | bash -s -- --dir /usr/local/bin && \
    (cp /root/.local/bin/agy /usr/local/bin/agy 2>/dev/null || true) && \
    chmod 755 /usr/local/bin/agy 2>/dev/null || true

# Create unprivileged reviewer user
RUN groupadd -g 10001 reviewer && \
    useradd -u 10001 -g reviewer -m -s /bin/bash reviewer && \
    groupadd -g 10002 rv && \
    useradd -u 10002 -g rv -M -d /home/rv -s /usr/sbin/nologin rv

# Create directory layout
RUN mkdir -p /var/lib/auto-review/clones \
             /run/auto-review \
             /usr/local/lib/auto-review \
             /usr/local/share/auto-review && \
    chown -R reviewer:reviewer /var/lib/auto-review /run/auto-review && \
    chmod 0700 /var/lib/auto-review /var/lib/auto-review/clones

# Copy auto-review tool, libraries, and adapters from auto-review/
COPY auto-review.sh /usr/local/bin/auto-review
COPY lib/ /usr/local/lib/auto-review/lib/
COPY adapters/ /usr/local/lib/auto-review/adapters/
COPY prompt/ /usr/local/lib/auto-review/prompt/
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod 755 /usr/local/bin/auto-review /usr/local/bin/entrypoint.sh

# No USER: compose starts it as uid 0 and entrypoint.sh drops to uid 10001.
WORKDIR /var/lib/auto-review

ENV AUTO_REVIEW_TOKEN_DIR=/run/auto-review \
    AUTO_REVIEW_REGISTRY=/var/lib/auto-review/projects.json \
    AUTO_REVIEW_CLONE_ROOT=/var/lib/auto-review/clones

VOLUME ["/var/lib/auto-review/clones"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["daemon"]
