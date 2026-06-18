# onboard.sh — interactive `psb init`. Phase 0 uses simple read-based prompts;
# a richer multiselect TUI is Phase 1. Writes config + secrets, checks prereqs,
# builds the image, runs one-time auth, installs the `psb` shim.
[[ -n "${_POLYSBX_ONBOARD:-}" ]] && return 0
_POLYSBX_ONBOARD=1
# shellcheck source=prereqs.sh
source "$POLYSBX_LIB/prereqs.sh"

_ask() {  # _ask VAR "prompt" "default"
    local __var="$1" __prompt="$2" __def="${3:-}" __ans
    read -rp "$__prompt${__def:+ [$__def]}: " __ans || true
    printf -v "$__var" '%s' "${__ans:-$__def}"
}
_ask_secret() {  # _ask_secret VAR "prompt"
    local __var="$1" __ans
    read -rsp "$2: " __ans || true; echo >&2
    printf -v "$__var" '%s' "$__ans"
}
_yes() { [[ "${1:-}" == [yY]* ]]; }

# _multiselect VAR "prompt" opt1 opt2 …  → VAR = space-separated chosen opts.
# Numbered toggle (type the numbers); avoids fragile raw-mode arrow-key TUIs that
# break across terminals. Blank picks nothing. Prompt/list go to stderr.
_multiselect() {
    local __var="$1" __prompt="$2"; shift 2
    local __opts=("$@") __i __ans __tok __chosen=()
    {   printf '%s\n' "$__prompt"
        for __i in "${!__opts[@]}"; do printf '  %d) %s\n' "$((__i+1))" "${__opts[$__i]}"; done
        printf '  (space/comma-separated numbers; blank = none)\n'
    } >&2
    read -rp "> " __ans || true
    for __tok in ${__ans//,/ }; do
        [[ "$__tok" =~ ^[0-9]+$ ]] && (( __tok>=1 && __tok<=${#__opts[@]} )) \
            && __chosen+=( "${__opts[$((__tok-1))]}" ) \
            || warn "ignoring '$__tok'"
    done
    printf -v "$__var" '%s' "${__chosen[*]:-}"   # :- so an empty pick is set -u safe (bash 3.2)
}

install_shim() {
    local bindir="$HOME/.local/bin" shim
    mkdir -p "$bindir"; shim="$bindir/psb"
    cat > "$shim" <<EOF
#!/usr/bin/env bash
exec bash "$POLYSBX_ROOT/bin/claude-harness" "\$@"
EOF
    chmod +x "$shim"
    info "Installed shim: $shim"
    case ":$PATH:" in
        *":$bindir:"*) ;;
        *) warn "$bindir is not on PATH — add: export PATH=\"$bindir:\$PATH\"" ;;
    esac
}

polysbx_init() {
    local os arch a
    os="$(detect_os)"; arch="$(detect_arch)"
    info "polysbx init — $os/$arch"

    local backend; _ask backend "Backend (docker | sbx | msbx)" "docker"
    case "$backend" in
        docker) ;;
        msbx)   warn "'msbx' (microsandbox) is wired up but beta — the microVM runtime is experimental." ;;
        sbx)    warn "'sbx' (Docker Sandboxes) is wired up but beta — auth is the host-keychain proxy ('sbx login'), and OAuth-token mode isn't supported." ;;
        *)      die "unknown backend: $backend" ;;
    esac

    check_docker || die "Install docker (instructions above), then re-run: psb init"
    [[ "$backend" != docker ]] && { check_backend_runtime "$backend" || die "Install the runtime above, then re-run: psb init"; }

    local authsel auth_mode
    _ask authsel "Auth: 1) subscription  2) api key  3) oauth token" "1"
    case "$authsel" in 2) auth_mode=apikey ;; 3) auth_mode=token ;; *) auth_mode=subscription ;; esac

    local langs;  _multiselect langs "Languages to bake into the image:" dotnet go python rust
    local cfgdir; _ask cfgdir  "Claude config dir" "$HOME/.claude"
    cfgdir="${cfgdir/#\~/$HOME}"
    if [[ -d "$cfgdir" ]]; then
        local found=() s
        for s in skills agents commands hooks rules settings.json; do
            [[ -e "$cfgdir/$s" ]] && found+=( "$s" )
        done
        info "config dir: $cfgdir  (found: ${found[*]:-nothing to stage})"
    else
        warn "config dir '$cfgdir' doesn't exist — it'll just stage nothing for now."
    fi

    local deny_merge=0 settings_example=0
    if [[ -f "$cfgdir/settings.json" ]]; then
        _ask a "Merge polysbx hardened deny-list into a polysbx copy of your settings.json? (y/N)" "N"
        _yes "$a" && deny_merge=1
    else
        _ask a "No settings.json in your config dir — install the hardened example? (y/N)" "N"
        _yes "$a" && settings_example=1
    fi

    local ado=0 gh=0 ado_pat="" gh_tok=""
    _ask a "Enable Azure DevOps integration (bundles azure-cli)? (y/N)" "N"
    if _yes "$a"; then ado=1; _ask_secret ado_pat "Azure DevOps PAT (Code scope; blank to add later)"; fi
    _ask a "Enable GitHub integration (bundles gh)? (y/N)" "N"
    if _yes "$a"; then gh=1; _ask_secret gh_tok "GitHub token (blank to add later)"; fi

    # Network egress. allowlist (default-deny + a curated allow-list covering
    # Anthropic, GitHub, and the package registries your selected languages need)
    # is only implemented for sbx/msbx; docker stays open in this build.
    local net_mode=open
    if [[ "$backend" != docker ]]; then
        _ask a "Restrict network egress to the polysbx allow-list (Anthropic, GitHub, package registries)? (y/N)" "N"
        _yes "$a" && net_mode=allowlist
    fi

    local api_key="" oauth_tok=""
    case "$auth_mode" in
        apikey) _ask_secret api_key   "ANTHROPIC_API_KEY" ;;
        token)  _ask_secret oauth_tok "CLAUDE_CODE_OAUTH_TOKEN" ;;
    esac

    mkdir -p "$POLYSBX_CONFIG_HOME"
    ( umask 077
      cat > "$CONFIG_FILE" <<EOF
BACKEND=$backend
AUTH_MODE=$auth_mode
LANGUAGES="$langs"
CONFIG_DIR="$cfgdir"
ADO_ENABLED=$ado
GH_ENABLED=$gh
DENY_MERGE=$deny_merge
SETTINGS_EXAMPLE=$settings_example
IMAGE_TAG=polysbx:latest
MEMORY=8g
CPUS=4
PIDS=256
NET_MODE=$net_mode
EOF
      : > "$SECRETS_FILE"; chmod 600 "$SECRETS_FILE"
      { [[ -n "$api_key" ]]   && printf 'ANTHROPIC_API_KEY=%q\n'        "$api_key"
        [[ -n "$oauth_tok" ]] && printf 'CLAUDE_CODE_OAUTH_TOKEN=%q\n'  "$oauth_tok"
        [[ -n "$ado_pat" ]]   && printf 'AZURE_DEVOPS_EXT_PAT=%q\n'     "$ado_pat"
        [[ -n "$gh_tok" ]]    && printf 'GITHUB_TOKEN=%q\n'             "$gh_tok"
      } >> "$SECRETS_FILE"
      : )   # the last guard may be false; keep the subshell's exit status 0 under set -e
    info "Wrote $CONFIG_FILE and $SECRETS_FILE (0600)."

    load_config; load_secrets
    local f="$POLYSBX_LIB/backend-$BACKEND.sh"
    if [[ ! -f "$f" ]]; then
        warn "backend '$BACKEND' not implemented in this build — config saved; re-run with docker to build."
        install_shim; return 0
    fi
    # shellcheck disable=SC1090
    source "$f"
    backend_build
    [[ "$auth_mode" == subscription ]] && backend_setup_auth
    install_shim
    cat >&2 <<EOF

✅ polysbx ready. From any repo:
     psb                       # launch Claude in the sandbox
     psb doctor                # verify the install
EOF
}
