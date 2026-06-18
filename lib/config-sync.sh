# config-sync.sh — stage the known config subpaths from the user's CONFIG_DIR
# into a polysbx-owned staging dir that the backends mount. The user's CONFIG_DIR
# is ALWAYS read-only source; nothing is ever written back to it.
#
# Credentials (.credentials.json / claude.json) are NEVER copied — they live in
# the per-backend managed home. settings.json is handled specially (§5 of SPEC):
# default copy, opt-in deny-merge into a polysbx-owned copy, or example install.
[[ -n "${_POLYSBX_CONFIG_SYNC:-}" ]] && return 0
_POLYSBX_CONFIG_SYNC=1

MANAGED_SUBPATHS=(skills agents commands hooks rules)

# staged_dir -> the deterministic staging path. Pure printf so it is safe to
# capture in "$(staged_dir)"; sync_config must NOT print it (it shells out to
# find, and a function that runs find can swallow trailing stdout under command
# substitution in some sandboxes — keep the data path and the work path apart).
staged_dir() { printf '%s\n' "$POLYSBX_CACHE_HOME/staged"; }

# sync_config [TARGET] -> stages config into TARGET (default "$(staged_dir)").
# Logs to stderr only. Only MANAGED_SUBPATHS + settings.json are removed/recopied,
# so TARGET may be a persistent home holding credentials + session state (the
# msbx backend points it at its shared Claude home) — those are left untouched.
sync_config() {
    local stage="${1:-$(staged_dir)}"
    local src="$CONFIG_DIR"

    # Guard: refuse obviously dangerous staging targets (we rm subpaths under it).
    case "$stage" in
        "" | "/" | "$HOME" | "$HOME/") die "refusing to stage config into '$stage'" ;;
    esac
    mkdir -p "$stage"

    local p
    for p in "${MANAGED_SUBPATHS[@]}"; do
        rm -rf "${stage:?}/$p"
        [[ -d "$src/$p" ]] && cp -R "$src/$p" "$stage/$p"
    done

    # settings.json
    rm -f "$stage/settings.json"
    if [[ -f "$src/settings.json" ]]; then
        if [[ "${DENY_MERGE:-0}" == 1 ]]; then
            merge_settings "$src/settings.json" "$stage/settings.json" \
                || { warn "deny-merge failed; using your settings.json verbatim"; cp "$src/settings.json" "$stage/settings.json"; }
        else
            cp "$src/settings.json" "$stage/settings.json"
        fi
    elif [[ "${SETTINGS_EXAMPLE:-0}" == 1 ]]; then
        cp "$POLYSBX_ROOT/templates/settings.example.json" "$stage/settings.json"
    fi

    find "$stage" -name '.DS_Store' -delete 2>/dev/null || true
    info "Synced config from $src → $stage"
}

# merge_settings <user-settings> <out> — union the packaged deny-list into the
# user's permissions.deny. Runs in-image with Node (the one guaranteed runtime;
# no host jq/python/node needed). Writes only to <out>, never the source.
merge_settings() {
    local user="$1" out="$2" deny
    deny="$(cat "$POLYSBX_ROOT/templates/deny-list.json")"
    mkdir -p "$(dirname "$out")"
    docker run --rm --entrypoint node \
        -v "$user:/in/settings.json:ro" \
        -v "$(cd "$(dirname "$out")" && pwd):/out" \
        -e "DENY_TEMPLATE=$deny" \
        "$IMAGE_TAG" -e '
            const fs = require("fs");
            const s = JSON.parse(fs.readFileSync("/in/settings.json", "utf8"));
            const extra = JSON.parse(process.env.DENY_TEMPLATE);
            s.permissions = s.permissions || {};
            const set = new Set(s.permissions.deny || []);
            for (const d of extra) set.add(d);
            s.permissions.deny = [...set];
            fs.writeFileSync("/out/" + "settings.json", JSON.stringify(s, null, 2));
        ' >&2
}
