# backend-msbx.sh — the microsandbox (microVM, libkrun) driver. Ports msbx/
# claude-msb.sh into polysbx's backend interface. Beta runtime. Expects common.sh
# sourced + load_config done. Shares the docker base image (built with docker,
# then `docker save | msb load` — microsandbox has no registry).
[[ -n "${_POLYSBX_BACKEND_MSBX:-}" ]] && return 0
_POLYSBX_BACKEND_MSBX=1

# shellcheck source=image.sh
source "$POLYSBX_LIB/image.sh"
# shellcheck source=config-sync.sh
source "$POLYSBX_LIB/config-sync.sh"
# shellcheck source=prereqs.sh
source "$POLYSBX_LIB/prereqs.sh"

# Shared, persistent Claude home: credentials + session + config in ONE dir, so
# the microVM needs only one virtio-fs device for it (msb allocates an fd per
# mount; too many EMFILE the VM). setup-auth logs in here once; every run mounts it.
MSBX_HOME="$POLYSBX_CACHE_HOME/msbx-home"
MSBX_CACHE_NUGET="$POLYSBX_CACHE_HOME/msbx-nuget"
MSBX_CACHE_GO="$POLYSBX_CACHE_HOME/msbx-go"
MSBX_CACHE_CARGO="$POLYSBX_CACHE_HOME/msbx-cargo"

# Egress allow-list applied when NET_MODE=allowlist (default-deny otherwise open).
MSBX_NET_ALLOW="allow@*.anthropic.com,allow@anthropic.com,allow@*.claude.com,allow@claude.com,allow@*.githubusercontent.com,allow@api.github.com,allow@api.nuget.org,allow@dev.azure.com,allow@login.microsoftonline.com,allow@packages.microsoft.com,allow@deb.nodesource.com,allow@proxy.golang.org,allow@sum.golang.org,allow@static.crates.io,allow@crates.io"

_image_loaded() { msb images 2>/dev/null | grep -q "${IMAGE_TAG%%:*}"; }

# libkrun allocates an fd per virtio-fs device while building the microVM; macOS
# defaults the soft open-file limit to 256, which EMFILEs once you have a handful
# of mounts. Raise the soft limit to the hard limit (best-effort).
_raise_nofile() {
    local hard; hard="$(ulimit -Hn 2>/dev/null || true)"
    case "$hard" in
        '' | unlimited) ulimit -Sn 65536 2>/dev/null || true ;;
        *)              ulimit -Sn "$hard" 2>/dev/null || true ;;
    esac
}

backend_build() {
    check_docker || die "docker prerequisite not met (needed to build the image)."
    check_backend_runtime msbx || die "msbx runtime prerequisite not met."
    local uid gid
    uid="$(effective_uid)"; gid="$(effective_gid)"
    info "Building $IMAGE_TAG  (uid=$uid gid=$gid; modules: $(selected_modules | tr '\n' ' '))"
    (   ctx="$(mktemp -d)"
        trap 'rm -rf "$ctx"' EXIT
        assemble_dockerfile "$POLYSBX_ROOT/image/Dockerfile.base.tmpl" "$ctx/Dockerfile"
        docker build \
            --build-arg HOST_UID="$uid" --build-arg HOST_GID="$gid" \
            -t "$IMAGE_TAG" -f "$ctx/Dockerfile" "$ctx"
        info "Loading $IMAGE_TAG into microsandbox (no registry — local archive)…"
        if ! docker save "$IMAGE_TAG" | msb load; then
            warn "pipe load failed; retrying via temp archive…"
            local tb; tb="$(mktemp -t polysbx-msbx.XXXXXX.tar)"
            docker save "$IMAGE_TAG" -o "$tb"
            msb load --input "$tb"
            rm -f "$tb"
        fi
    )
}

backend_setup_auth() {
    [[ "$AUTH_MODE" == subscription ]] || { info "AUTH_MODE=$AUTH_MODE uses an env credential — no login needed."; return 0; }
    _image_loaded || backend_build
    _raise_nofile
    mkdir -p "$MSBX_HOME"
    sync_config "$MSBX_HOME" >/dev/null || true   # give the login session normal config
    info "One-time Claude login — run /login, finish in the browser, then /exit."
    # Mount only the shared home; egress limited to the OAuth exchange. No project.
    msb run "$IMAGE_TAG" \
        -m 2G -c 2 \
        -v "$MSBX_HOME:/home/claude/.claude" \
        --net-default deny \
        --net-rule "allow@*.anthropic.com,allow@anthropic.com,allow@*.claude.com,allow@claude.com" \
        -w /home/claude \
        -- claude || true
    if [[ -f "$MSBX_HOME/.credentials.json" ]]; then
        info "Logged in — credential stored in $MSBX_HOME."
    else
        warn "no .credentials.json written — login may not have completed; re-run: psb setup-auth"
    fi
}

backend_run() {
    check_backend_runtime msbx || die "msbx runtime prerequisite not met."
    _image_loaded || { warn "image $IMAGE_TAG not loaded — building now."; backend_build; }
    _raise_nofile

    local project langs
    project="$(resolve_project_dir)"
    langs=" $LANGUAGES "

    mkdir -p "$MSBX_HOME"
    sync_config "$MSBX_HOME"

    # First-run guard: a shared home with no credential means setup-auth hasn't run.
    if [[ "$AUTH_MODE" == subscription && ! -f "$MSBX_HOME/.credentials.json" ]]; then
        warn "not logged in (no credential in $MSBX_HOME) — run: psb setup-auth"
    fi

    # Mounts: keep the count low (one fd per virtio-fs device). The whole Claude
    # home is ONE mount, not per-subpath overlays like the docker backend.
    local mounts=(
        -v "$project:$project"
        -v "$MSBX_HOME:/home/claude/.claude"
    )
    [[ -f "$HOME/.gitconfig" ]] && mounts+=( -v "$HOME/.gitconfig:/home/claude/.gitconfig:ro" )
    [[ -d "$HOME/.ssh" ]]       && mounts+=( -v "$HOME/.ssh:/home/claude/.ssh:ro" )

    local envs=()
    if [[ "$langs" == *" dotnet "* ]]; then
        mkdir -p "$MSBX_CACHE_NUGET"; mounts+=( -v "$MSBX_CACHE_NUGET:/home/claude/.nuget" )
        envs+=( -e "DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=0" )
    fi
    if [[ "$langs" == *" go "* ]]; then
        mkdir -p "$MSBX_CACHE_GO"; mounts+=( -v "$MSBX_CACHE_GO:/home/claude/go" )
    fi
    if [[ "$langs" == *" rust "* ]]; then
        mkdir -p "$MSBX_CACHE_CARGO"; mounts+=( -v "$MSBX_CACHE_CARGO:/home/claude/.cargo" )
        envs+=( -e "CARGO_HOME=/home/claude/.cargo" )
    fi

    # Egress: default-deny + allow-list when NET_MODE=allowlist; else open.
    local net=()
    if [[ "${NET_MODE:-open}" == allowlist ]]; then
        net=( --net-default deny --net-rule "$MSBX_NET_ALLOW" )
    fi

    # Auth (see SPEC §6). microsandbox -e takes KEY=VALUE only (no bare inherit).
    # Subscription uses the credential seeded into $MSBX_HOME; we deliberately do
    # NOT pass CLAUDE_CODE_OAUTH_TOKEN in that mode (it overrides a good login).
    case "$AUTH_MODE" in
        apikey) [[ -n "${ANTHROPIC_API_KEY:-}" ]] && envs+=( -e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY" ) \
                    || warn "AUTH_MODE=apikey but ANTHROPIC_API_KEY is unset." ;;
        token)  [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]] && envs+=( -e "CLAUDE_CODE_OAUTH_TOKEN=$CLAUDE_CODE_OAUTH_TOKEN" ) \
                    || warn "AUTH_MODE=token but CLAUDE_CODE_OAUTH_TOKEN is unset." ;;
        subscription) : ;;
    esac
    [[ "${ADO_ENABLED:-0}" == 1 && -n "${AZURE_DEVOPS_EXT_PAT:-}" ]] && envs+=( -e "AZURE_DEVOPS_EXT_PAT=$AZURE_DEVOPS_EXT_PAT" )
    [[ "${GH_ENABLED:-0}"  == 1 && -n "${GITHUB_TOKEN:-}" ]]        && envs+=( -e "GITHUB_TOKEN=$GITHUB_TOKEN" )

    info "microsandbox '$IMAGE_TAG' → $project"
    # msb wants memory like "8G" (uppercase). Uppercase via tr, not ${MEMORY^^},
    # which is bash 4+ only and breaks on macOS's system bash 3.2.
    local mem; mem="$(printf '%s' "$MEMORY" | LC_ALL=C tr 'a-z' 'A-Z')"
    # microsandbox auto-detects the interactive TTY; the microVM is the sandbox.
    # net[]/envs[] may be empty (open egress, no extra env). Expanding an empty
    # array as "${a[@]}" under set -u errors on bash 3.2 (fixed in 4.4); the
    # ${a[@]+"${a[@]}"} idiom expands to nothing safely on every bash.
    exec msb run "$IMAGE_TAG" \
        -m "$mem" -c "$CPUS" \
        "${mounts[@]}" \
        ${net[@]+"${net[@]}"} \
        -w "$project" \
        ${envs[@]+"${envs[@]}"} \
        -- claude --dangerously-skip-permissions "$@"
}

backend_doctor() {
    local ok=0
    info "config: backend=$BACKEND auth=$AUTH_MODE languages='${LANGUAGES:-none}' ado=$ADO_ENABLED gh=$GH_ENABLED net=$NET_MODE"
    check_docker && info "docker (build): ok" || { warn "docker needed to (re)build the image"; ok=1; }
    check_backend_runtime msbx && info "msb runtime: ok" || ok=1
    if _image_loaded; then
        info "image $IMAGE_TAG: loaded"
    else
        warn "image $IMAGE_TAG: not loaded (run: psb build)"; ok=1
    fi
    if [[ "$AUTH_MODE" == subscription ]]; then
        [[ -f "$MSBX_HOME/.credentials.json" ]] \
            && info "credential: present in $MSBX_HOME" \
            || { warn "no credential in $MSBX_HOME — run: psb setup-auth"; ok=1; }
    fi
    [[ "$ok" == 0 ]] && info "doctor: all good." || warn "doctor: issues above."
    return "$ok"
}

backend_clean() {
    command -v msb >/dev/null 2>&1 || { warn "msb not installed — nothing to clean."; return 0; }
    info "polysbx microsandbox sandboxes (image match: ${IMAGE_TAG%%:*}):"
    msb ls 2>/dev/null | grep -E "${IMAGE_TAG%%:*}|NAME" >&2 || true
    local ans
    read -rp "Remove stopped polysbx sandboxes and the cache (home/nuget/go/cargo)? [y/N] " ans
    [[ "$ans" == [yY]* ]] || { info "aborted."; return 0; }

    # Remove only sandboxes whose `msb ls` row mentions our image (conservative —
    # leaves other microsandboxes and running ones alone). Layout is beta; errs
    # toward removing nothing rather than the wrong thing.
    local line name
    while IFS= read -r line; do
        case "$line" in *"${IMAGE_TAG%%:*}"*) ;; *) continue ;; esac
        grep -qiw running <<<"$line" && { warn "skipping running: $(awk '{print $1}' <<<"$line")"; continue; }
        name="$(awk '{print $1}' <<<"$line")"; [[ -z "$name" ]] && continue
        msb rm "$name" </dev/null >/dev/null 2>&1 || msb rm -f "$name" </dev/null >/dev/null 2>&1 || warn "could not remove $name"
    done < <(msb ls 2>/dev/null | tail -n +2)

    rm -rf "$MSBX_HOME" "$MSBX_CACHE_NUGET" "$MSBX_CACHE_GO" "$MSBX_CACHE_CARGO"
    info "cleaned cache (removing the home cleared the saved login — re-run: psb setup-auth)."
    warn "the image stays loaded in microsandbox; rebuild with 'psb build' overwrites it."
}
