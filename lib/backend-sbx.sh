# backend-sbx.sh — the Docker Sandboxes (sbx) driver. Ports sbx/claude-sbx.sh
# into polysbx's backend interface. Beta runtime. Expects common.sh sourced +
# load_config done.
#
# Model (different from docker/msbx): the image is an sbx *template* and the
# behaviour is an sbx *kit* (`extends: claude`, the built-in agent). Auth is the
# host-keychain OAuth proxy (`sbx login`) — there is NO managed-home credential
# file. Each run generates a fresh per-instance kit in /tmp (parallel-safe),
# stages config + a generated spec.yaml into it, and launches a uniquely-named
# sandbox bound to the current project. On exit the sandbox is stopped (kept for
# `claude --resume`); `psb clean` reaps stopped ones.
[[ -n "${_POLYSBX_BACKEND_SBX:-}" ]] && return 0
_POLYSBX_BACKEND_SBX=1

# shellcheck source=image.sh
source "$POLYSBX_LIB/image.sh"
# shellcheck source=config-sync.sh
source "$POLYSBX_LIB/config-sync.sh"
# shellcheck source=prereqs.sh
source "$POLYSBX_LIB/prereqs.sh"

_image_loaded() { sbx template ls 2>/dev/null | grep -q "${IMAGE_TAG%%:*}"; }

# Egress allow-list (bare domains; sbx's `network.allowedDomains` form). Built
# from the selected modules so we only open what the chosen toolchains need.
# Applied to the generated kit only when NET_MODE=allowlist (else egress is open).
_sbx_allowed_domains() {
    printf '%s\n' api.anthropic.com
    local langs=" $LANGUAGES "
    [[ "$langs" == *" dotnet "* ]] && printf '%s\n' api.nuget.org packages.microsoft.com
    [[ "$langs" == *" go "* ]]     && printf '%s\n' proxy.golang.org sum.golang.org
    [[ "$langs" == *" rust "* ]]   && printf '%s\n' static.crates.io crates.io index.crates.io
    [[ "${ADO_ENABLED:-0}" == 1 ]] && printf '%s\n' dev.azure.com login.microsoftonline.com packages.microsoft.com
    [[ "${GH_ENABLED:-0}"  == 1 ]] && printf '%s\n' api.github.com github.com codeload.github.com
}

backend_build() {
    check_docker || die "docker prerequisite not met (needed to build the image)."
    check_backend_runtime sbx || die "sbx runtime prerequisite not met."
    # Unlike docker/msbx (which bind-mount the project at the host uid), the sbx
    # sandbox runs as the base image's built-in `agent` user (uid/gid 1000). The
    # macOS host uid is irrelevant inside the sandbox, so build the in-image
    # /home/claude and Go/Rust caches owned by the agent — otherwise the runtime
    # user can't write them.
    local uid=1000 gid=1000
    info "Building $IMAGE_TAG  (agent uid=$uid gid=$gid; modules: $(selected_modules | tr '\n' ' '))"
    (   ctx="$(mktemp -d)"
        trap 'rm -rf "$ctx"' EXIT
        assemble_dockerfile "$POLYSBX_ROOT/image/Dockerfile.sbx.tmpl" "$ctx/Dockerfile"
        docker build \
            --build-arg HOST_UID="$uid" --build-arg HOST_GID="$gid" \
            -t "$IMAGE_TAG" -f "$ctx/Dockerfile" "$ctx"
        info "Loading $IMAGE_TAG into sbx (no registry — local archive)…"
        local tb; tb="$(mktemp -t polysbx-sbx.XXXXXX.tar)"
        docker image save "$IMAGE_TAG" -o "$tb"
        sbx template load "$tb"
        rm -f "$tb"
    )
}

backend_setup_auth() {
    check_backend_runtime sbx || die "sbx runtime prerequisite not met."
    case "$AUTH_MODE" in
        subscription)
            info "Logging into Claude via sbx (host-keychain proxy — persists across runs)…"
            sbx login || warn "sbx login did not complete — re-run: psb setup-auth" ;;
        apikey)
            info "AUTH_MODE=apikey — the key is injected into the sandbox env at run time; no sbx login needed." ;;
        token)
            warn "sbx does not support CLAUDE_CODE_OAUTH_TOKEN (docker/sbx-releases#11)."
            warn "Falling back to the host-keychain proxy — running 'sbx login' instead."
            sbx login || warn "sbx login did not complete — re-run: psb setup-auth" ;;
    esac
}

# _sbx_write_spec <spec-path> — generate the per-instance kit spec.yaml. Network
# block is conditional (NET_MODE); secrets are inlined into the /tmp copy only
# (never committed, never logged). Startup commands ported from sbx/kit/spec.yaml.
_sbx_write_spec() {
    local spec="$1" d
    {
        cat <<'YAML'
schemaVersion: "1"
kind: mixin
name: polysbx
displayName: polysbx (sandboxed Claude)
description: polysbx-staged config, deny-list/hooks, optional network allow-list
extends: claude
YAML
        if [[ "${NET_MODE:-open}" == allowlist ]]; then
            printf 'network:\n  allowedDomains:\n'
            while IFS= read -r d; do printf '    - %s\n' "$d"; done < <(_sbx_allowed_domains | sort -u)
        fi
        printf 'environment:\n  variables:\n'
        printf '    DOTNET_CLI_TELEMETRY_OPTOUT: "1"\n'
        printf '    DOTNET_SYSTEM_GLOBALIZATION_INVARIANT: "1"\n'
        # sbx accepts ANTHROPIC_API_KEY for api-key mode (SPEC §14 Q1 — verify on
        # a real host; harmless if ignored, the proxy still provides subscription).
        [[ "$AUTH_MODE" == apikey && -n "${ANTHROPIC_API_KEY:-}" ]] \
            && printf "    ANTHROPIC_API_KEY: '%s'\n" "$ANTHROPIC_API_KEY"
        # ADO PAT inlined here (per-instance /tmp kit only) so `az devops` and the
        # git extraHeader authenticate without an interactive login.
        [[ "${ADO_ENABLED:-0}" == 1 && -n "${AZURE_DEVOPS_EXT_PAT:-}" ]] \
            && printf "    AZURE_DEVOPS_EXT_PAT: '%s'\n" "$AZURE_DEVOPS_EXT_PAT"
        [[ "${GH_ENABLED:-0}" == 1 && -n "${GITHUB_TOKEN:-}" ]] \
            && printf "    GITHUB_TOKEN: '%s'\n" "$GITHUB_TOKEN"
        cat <<'YAML'
commands:
  startup:
    # Config ships at user level via files/home/.claude (→ /home/agent/.claude),
    # sandbox-only — never written into the bind-mounted project dir. The built-in
    # claude agent re-seeds ~/.claude/settings.json AFTER static kit files, so we
    # install OURS (staged to ~/.claude-bootstrap) over the seeded one here.
    - description: Install our settings.json (deny-list/model/hooks) over the seeded one
      user: "1000"
      command:
        - bash
        - -lc
        - 'src="$HOME/.claude-bootstrap/settings.json"; if [ -f "$src" ]; then mkdir -p "$HOME/.claude"; cp "$src" "$HOME/.claude/settings.json"; fi'
    # Fallback: strip the proxy-managed apiKeyHelper the seeding injects, which
    # breaks Pro/Max OAuth (docker/for-mac#7842).
    - description: Strip proxy-managed apiKeyHelper so Pro/Max OAuth works (docker/for-mac#7842)
      user: "1000"
      command:
        - bash
        - -lc
        - 'f="$HOME/.claude/settings.json"; if [ -f "$f" ]; then sed -i "/\"apiKeyHelper\"/d" "$f"; fi'
    # Wire the injected ADO PAT into git so fetch/pull/push to dev.azure.com
    # authenticates over HTTPS (the env var alone is only read by `az devops`).
    - description: Configure git to authenticate to Azure DevOps with the injected PAT
      user: "1000"
      command:
        - bash
        - -lc
        - 'if [ -n "${AZURE_DEVOPS_EXT_PAT:-}" ]; then hdr=$(printf ":%s" "$AZURE_DEVOPS_EXT_PAT" | base64 | tr -d "\n"); git config --global "http.https://dev.azure.com/.extraHeader" "Authorization: Basic $hdr"; fi'
    # Block pushes to main/master/dev from inside the sandbox (feature branches
    # still push, so ship/az-create-pr work). A pre-push hook is the only guard
    # that sees the resolved remote ref for every push form.
    - description: Install a pre-push hook blocking pushes to main/master/dev
      user: "1000"
      command:
        - bash
        - -lc
        - |
          mkdir -p "$HOME/.git-hooks"
          cat > "$HOME/.git-hooks/pre-push" <<'PPEOF'
          #!/usr/bin/env bash
          # Reject pushes to protected branches from inside the sandbox.
          # stdin: "<local ref> <local sha> <remote ref> <remote sha>" per ref.
          while read -r _lref _lsha remote_ref _rsha; do
            branch="${remote_ref#refs/heads/}"
            case "$branch" in
              main|master|dev)
                echo "pre-push: refusing to push to protected branch '$branch' (sandbox policy)" >&2
                exit 1
                ;;
            esac
          done
          exit 0
          PPEOF
          chmod +x "$HOME/.git-hooks/pre-push"
          git config --global core.hooksPath "$HOME/.git-hooks"
YAML
    } > "$spec"
}

backend_run() {
    check_backend_runtime sbx || die "sbx runtime prerequisite not met."
    _image_loaded || { warn "template $IMAGE_TAG not loaded — building now."; backend_build; }

    local project slug name
    project="$(resolve_project_dir)"
    slug="$(basename "$project" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -c 'a-z0-9' '-')"
    slug="${slug#-}"; slug="${slug%-}"
    name="polysbx-${slug}-$$-${RANDOM}"

    [[ "$AUTH_MODE" == token ]] && warn "sbx ignores CLAUDE_CODE_OAUTH_TOKEN; using the host-keychain proxy (run 'psb setup-auth' if not logged in)."

    # Per-instance kit snapshot in /tmp (parallel-safe). Build it, run inside a
    # subshell whose EXIT trap cleans up — keeps the trap's vars in scope (a
    # process-level EXIT trap would fire after the function returns, with locals
    # gone → unbound under set -u).
    (   local tmp_parent kit claudedir boot
        tmp_parent="$(mktemp -d)"
        trap 'rm -rf "$tmp_parent"; sbx stop "$name" </dev/null >/dev/null 2>&1 || true' EXIT
        kit="$tmp_parent/kit"
        claudedir="$kit/files/home/.claude"
        boot="$kit/files/home/.claude-bootstrap"
        mkdir -p "$claudedir" "$boot"

        # Stage config into the kit's user-level ~/.claude (sandbox-only).
        sync_config "$claudedir"

        # settings.json must NOT sit in ~/.claude (the agent re-seeds it); move it
        # to the bootstrap dir a startup command installs from. Rewrite the hook
        # node path for this base image (/usr/bin/node → node).
        if [[ -f "$claudedir/settings.json" ]]; then
            sed 's#/usr/bin/node#node#g' "$claudedir/settings.json" > "$boot/settings.json"
            rm -f "$claudedir/settings.json"
        fi

        _sbx_write_spec "$kit/spec.yaml"

        info "sbx instance '$name' → $project"
        sbx run claude "$project" \
            --name "$name" \
            --template "$IMAGE_TAG" \
            --kit "$kit" \
            -- --dangerously-skip-permissions "$@"
    )
}

backend_doctor() {
    local ok=0
    info "config: backend=$BACKEND auth=$AUTH_MODE languages='${LANGUAGES:-none}' ado=$ADO_ENABLED gh=$GH_ENABLED net=$NET_MODE"
    check_docker && info "docker (build): ok" || { warn "docker needed to (re)build the image"; ok=1; }
    check_backend_runtime sbx && info "sbx runtime: ok" || ok=1
    if _image_loaded; then
        info "template $IMAGE_TAG: loaded"
    else
        warn "template $IMAGE_TAG: not loaded (run: psb build)"; ok=1
    fi
    case "$AUTH_MODE" in
        subscription|token) info "auth: host-keychain proxy via 'sbx login' (no local credential file to check)." ;;
        apikey)             [[ -n "${ANTHROPIC_API_KEY:-}" ]] && info "auth: ANTHROPIC_API_KEY present." \
                                || { warn "AUTH_MODE=apikey but ANTHROPIC_API_KEY is unset."; ok=1; } ;;
    esac
    [[ "$ok" == 0 ]] && info "doctor: all good." || warn "doctor: issues above."
    return "$ok"
}

backend_clean() {
    command -v sbx >/dev/null 2>&1 || { warn "sbx not installed — nothing to clean."; return 0; }
    local include_running=0
    [[ "${1:-}" == --all ]] && include_running=1

    # sbx ls columns: SANDBOX AGENT STATUS …  → only our 'polysbx-' instances.
    local targets=() name status
    while read -r name status; do
        [[ -z "$name" ]] && continue
        if [[ "$status" == running ]]; then
            if [[ "$include_running" == 1 ]]; then
                info "stopping running: $name"; sbx stop "$name" </dev/null >/dev/null 2>&1 || true
                targets+=( "$name" )
            else
                warn "skipping running: $name  (use 'psb clean --all' to include)"
            fi
        else
            targets+=( "$name" )
        fi
    done < <(sbx ls 2>/dev/null | awk 'NR>1 && $1 ~ /^polysbx-/ { print $1, $3 }')

    if [[ "${#targets[@]}" -eq 0 ]]; then info "no polysbx sbx sandboxes to remove."; return 0; fi
    info "removing ${#targets[@]} sandbox(es): ${targets[*]}"
    sbx rm -f "${targets[@]}"
    warn "the template stays loaded in sbx; 'psb build' overwrites it."
}
