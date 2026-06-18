# backend-docker.sh — the docker driver. Ports the hardened claude-docker.sh into
# polysbx's backend interface: backend_build / backend_run / backend_setup_auth /
# backend_doctor / backend_clean. Expects common.sh sourced + load_config done.
[[ -n "${_POLYSBX_BACKEND_DOCKER:-}" ]] && return 0
_POLYSBX_BACKEND_DOCKER=1

# shellcheck source=image.sh
source "$POLYSBX_LIB/image.sh"
# shellcheck source=config-sync.sh
source "$POLYSBX_LIB/config-sync.sh"
# shellcheck source=prereqs.sh
source "$POLYSBX_LIB/prereqs.sh"

AUTH_VOLUME=polysbx-auth
NUGET_VOLUME=polysbx-nuget
GO_VOLUME=polysbx-go
CARGO_VOLUME=polysbx-cargo

_image_built() { docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; }

backend_build() {
    check_docker || die "docker prerequisite not met."
    local uid gid
    uid="$(effective_uid)"; gid="$(effective_gid)"
    info "Building $IMAGE_TAG  (uid=$uid gid=$gid; modules: $(selected_modules | tr '\n' ' '))"
    # Build context in a subshell so the cleanup trap is scoped to it (a RETURN
    # trap is global and would re-fire on every later function return).
    (   ctx="$(mktemp -d)"
        trap 'rm -rf "$ctx"' EXIT
        assemble_dockerfile "$POLYSBX_ROOT/image/Dockerfile.base.tmpl" "$ctx/Dockerfile"
        docker build \
            --build-arg HOST_UID="$uid" --build-arg HOST_GID="$gid" \
            -t "$IMAGE_TAG" -f "$ctx/Dockerfile" "$ctx"
    )
}

backend_setup_auth() {
    [[ "$AUTH_MODE" == subscription ]] || { info "AUTH_MODE=$AUTH_MODE uses an env credential — no login needed."; return 0; }
    _image_built || backend_build
    local uid gid o
    uid="$(effective_uid)"; gid="$(effective_gid)"; o="uid=$uid,gid=$gid"
    info "One-time Claude login — run /login, finish in the browser, then /exit."
    docker run -it --rm -u "$uid:$gid" \
        -v "$AUTH_VOLUME:/home/claude/.claude" \
        --tmpfs "/home/claude/.cache:rw,size=128m,$o" \
        --tmpfs "/home/claude/.config:rw,size=32m,$o" \
        "$IMAGE_TAG"
}

backend_run() {
    check_docker >/dev/null || die "docker prerequisite not met."
    _image_built || { warn "image $IMAGE_TAG not built — building now."; backend_build; }

    local project stage uid gid o langs
    project="$(resolve_project_dir)"
    sync_config; stage="$(staged_dir)"
    uid="$(effective_uid)"; gid="$(effective_gid)"; o="uid=$uid,gid=$gid"
    langs=" $LANGUAGES "

    local mounts=(
        -v "$project:$project"
        -v "$AUTH_VOLUME:/home/claude/.claude"
    )
    local p
    for p in "${MANAGED_SUBPATHS[@]}"; do
        [[ -e "$stage/$p" ]] && mounts+=( -v "$stage/$p:/home/claude/.claude/$p:ro" )
    done
    [[ -f "$stage/settings.json" ]] && mounts+=( -v "$stage/settings.json:/home/claude/.claude/settings.json:ro" )
    [[ -f "$HOME/.gitconfig" ]]     && mounts+=( -v "$HOME/.gitconfig:/home/claude/.gitconfig:ro" )
    [[ -d "$HOME/.ssh" ]]           && mounts+=( -v "$HOME/.ssh:/home/claude/.ssh:ro" )

    local security=(
        -u "$uid:$gid"
        --cap-drop=ALL --security-opt=no-new-privileges:true --read-only
        --tmpfs "/tmp:rw,noexec,nosuid,size=512m,$o"
        --tmpfs "/home/claude/.cache:rw,size=256m,$o"
        --tmpfs "/home/claude/.config:rw,size=32m,$o"
        --tmpfs "/home/claude/.local/share/applications:rw,size=1m,$o"
    )
    local envs=()

    if [[ "$langs" == *" dotnet "* ]]; then
        mounts+=( -v "$NUGET_VOLUME:/home/claude/.nuget" )
        security+=( --tmpfs "/home/claude/.dotnet:rw,size=256m,$o"
                    --tmpfs "/home/claude/.local/share/NuGet:rw,size=128m,$o" )
        envs+=( -e DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=0 )
    fi
    [[ "$langs" == *" go "* ]] && mounts+=( -v "$GO_VOLUME:/home/claude/go" )
    if [[ "$langs" == *" rust "* ]]; then
        # CARGO_HOME holds the registry/cache; the rootfs is read-only, so point it
        # at a persisted volume (the cargo/rustc binaries live in /usr/local/cargo,
        # outside this mount, and stay on PATH).
        mounts+=( -v "$CARGO_VOLUME:/home/claude/.cargo" )
        envs+=( -e CARGO_HOME=/home/claude/.cargo )
    fi

    # Auth (see SPEC §6). Subscription uses the credential persisted in $AUTH_VOLUME.
    case "$AUTH_MODE" in
        apikey) [[ -n "${ANTHROPIC_API_KEY:-}" ]] && envs+=( -e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY" ) \
                    || warn "AUTH_MODE=apikey but ANTHROPIC_API_KEY is unset." ;;
        token)  [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]] && envs+=( -e "CLAUDE_CODE_OAUTH_TOKEN=$CLAUDE_CODE_OAUTH_TOKEN" ) \
                    || warn "AUTH_MODE=token but CLAUDE_CODE_OAUTH_TOKEN is unset." ;;
        subscription) : ;;
    esac
    [[ "${ADO_ENABLED:-0}" == 1 && -n "${AZURE_DEVOPS_EXT_PAT:-}" ]] && envs+=( -e "AZURE_DEVOPS_EXT_PAT=$AZURE_DEVOPS_EXT_PAT" )
    [[ "${GH_ENABLED:-0}"  == 1 && -n "${GITHUB_TOKEN:-}" ]]        && envs+=( -e "GITHUB_TOKEN=$GITHUB_TOKEN" )

    local limits=( --memory="$MEMORY" --cpus="$CPUS" --pids-limit="$PIDS" )
    local tty=(-i); [[ -t 0 && -t 1 ]] && tty=(-it)

    info "docker '$IMAGE_TAG' → $project"
    # envs[] may be empty; ${a[@]+"${a[@]}"} avoids set -u erroring on an empty
    # array expansion under bash 3.2 (macOS system bash).
    exec docker run "${tty[@]}" --rm \
        "${mounts[@]}" "${security[@]}" "${limits[@]}" ${envs[@]+"${envs[@]}"} \
        -w "$project" "$IMAGE_TAG" --dangerously-skip-permissions "$@"
}

# Probe a tool inside the built image: _tool_in_image <entrypoint> [args…]
_tool_in_image() { docker run --rm --entrypoint "$1" "$IMAGE_TAG" "${@:2}" 2>/dev/null; }

backend_doctor() {
    local ok=0
    info "config: backend=$BACKEND auth=$AUTH_MODE languages='${LANGUAGES:-none}' ado=$ADO_ENABLED gh=$GH_ENABLED"
    check_docker && info "docker: ok" || ok=1
    if _image_built; then
        info "image $IMAGE_TAG: present"
        local v; v="$(docker run --rm --entrypoint claude "$IMAGE_TAG" --version 2>/dev/null || true)"
        [[ -n "$v" ]] && info "claude in image: $v" || { warn "could not run claude in image"; ok=1; }
        # Verify each selected language/integration tool actually runs in the image.
        local m probe out
        for m in $(selected_modules); do
            case "$m" in
                dotnet)    probe=(dotnet --version) ;;
                go)        probe=(go version) ;;
                python)    probe=(python3 --version) ;;
                rust)      probe=(cargo --version) ;;
                azure-cli) probe=(az version) ;;
                gh)        probe=(gh --version) ;;
                *) continue ;;
            esac
            out="$(_tool_in_image "${probe[0]}" "${probe[@]:1}" | head -1)"
            [[ -n "$out" ]] && info "  $m: $out" || { warn "  $m: tool not runnable in image"; ok=1; }
        done
    else
        warn "image $IMAGE_TAG: not built (run: psb build)"; ok=1
    fi
    if [[ "$AUTH_MODE" == subscription ]]; then
        docker volume inspect "$AUTH_VOLUME" >/dev/null 2>&1 \
            && info "auth volume $AUTH_VOLUME: present" \
            || { warn "no auth volume — run: psb setup-auth"; ok=1; }
    fi
    [[ "$ok" == 0 ]] && info "doctor: all good." || warn "doctor: issues above."
    return "$ok"
}

backend_clean() {
    info "polysbx docker volumes:"; docker volume ls --filter name=polysbx- >&2 || true
    local ans
    read -rp "Remove polysbx volumes (auth/nuget/go/cargo) and image $IMAGE_TAG? [y/N] " ans
    [[ "$ans" == [yY]* ]] || { info "aborted."; return 0; }
    docker volume rm "$AUTH_VOLUME" "$NUGET_VOLUME" "$GO_VOLUME" "$CARGO_VOLUME" 2>/dev/null || true
    docker image rm "$IMAGE_TAG" 2>/dev/null || true
    info "cleaned."
}
