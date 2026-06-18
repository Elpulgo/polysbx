# Go toolchain. TARGETARCH (BuildKit) maps to Go's linux-amd64 / linux-arm64.
ARG GO_VERSION=1.26.1
ARG TARGETARCH
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${TARGETARCH}.tar.gz" -o /tmp/go.tgz \
    && tar -C /usr/local -xzf /tmp/go.tgz && rm /tmp/go.tgz \
    && mkdir -p /home/claude/go/bin /home/claude/go/cache /home/claude/go/tmp /home/claude/go/pkg \
    && chown -R "$HOST_UID:$HOST_GID" /home/claude/go
# GOTMPDIR must be exec-allowed; the harness mounts /tmp noexec, so keep Go's
# scratch on the (persisted, exec-friendly) go volume.
ENV PATH="/usr/local/go/bin:/home/claude/go/bin:$PATH" \
    GOPATH=/home/claude/go \
    GOCACHE=/home/claude/go/cache \
    GOTMPDIR=/home/claude/go/tmp
