# prereqs.sh — detect required runtimes. DETECT AND INSTRUCT ONLY; polysbx never
# installs anything for the user. Returns non-zero (after printing instructions)
# when a prerequisite is missing, so the caller can stop and ask for a re-run.
[[ -n "${_POLYSBX_PREREQS:-}" ]] && return 0
_POLYSBX_PREREQS=1

# docker is required for EVERY backend — all three build the OCI image with
# `docker build` (docker runs it directly; sbx/msbx then load the saved image).
check_docker() {
    local os; os="$(detect_os)"
    if ! command -v docker >/dev/null 2>&1; then
        err "docker not found — required to build the image (all backends)."
        if [[ "$os" == macos ]]; then
            cat >&2 <<'EOF'
   Install Docker Desktop or OrbStack, then re-run `psb init`:
     https://www.docker.com/products/docker-desktop/   (or)  https://orbstack.dev
EOF
        else
            cat >&2 <<'EOF'
   Install Docker Engine, add yourself to the `docker` group, then re-run `psb init`:
     curl -fsSL https://get.docker.com | sh
     sudo usermod -aG docker "$USER"   # then log out/in so the group takes effect
EOF
        fi
        return 1
    fi
    if ! docker info >/dev/null 2>&1; then
        err "docker is installed but the daemon isn't reachable."
        [[ "$os" == linux ]] && err "On Linux this is usually the 'docker' group — log out/in after: sudo usermod -aG docker \"\$USER\"."
        [[ "$os" == macos ]] && err "Start Docker Desktop / OrbStack and re-run."
        return 1
    fi
    return 0
}

# Backend-specific RUN runtime (docker reuses docker; sbx/msbx need their own).
check_backend_runtime() {
    local backend="$1" os arch
    os="$(detect_os)"; arch="$(detect_arch)"
    case "$backend" in
        docker) return 0 ;;
        sbx)
            command -v sbx >/dev/null 2>&1 && return 0
            err "sbx not found (Docker Sandboxes — beta)."
            if [[ "$os" == macos ]]; then
                err "   brew install docker/tap/sbx && sbx login    # then re-run psb init"
            else
                err "   sbx is Docker-Desktop-coupled; Linux support is limited. See docker docs."
            fi
            return 1 ;;
        msbx)
            if ! command -v msb >/dev/null 2>&1; then
                err "msb not found (microsandbox — beta)."
                [[ "$os" == macos ]] && err "   brew install superradcompany/tap/microsandbox    # then re-run psb init"
                [[ "$os" == linux ]] && err "   Install microsandbox (needs KVM). See https://microsandbox.dev"
                return 1
            fi
            if [[ "$os" == macos && "$arch" != arm64 ]]; then
                err "microsandbox on macOS requires Apple Silicon (arm64); this is $arch."
                return 1
            fi
            if [[ "$os" == linux && ! -e /dev/kvm ]]; then
                err "microsandbox needs KVM, but /dev/kvm is missing. Enable virtualization."
                return 1
            fi
            return 0 ;;
        *) die "unknown backend: $backend" ;;
    esac
}
