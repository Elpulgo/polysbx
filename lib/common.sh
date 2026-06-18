# common.sh — shared helpers: config/secrets loading, detection, logging.
# Sourced by bin/claude-harness and the lib/* files. Not executable on its own.
[[ -n "${_POLYSBX_COMMON:-}" ]] && return 0
_POLYSBX_COMMON=1

POLYSBX_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}/polysbx"
POLYSBX_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}/polysbx"
CONFIG_FILE="$POLYSBX_CONFIG_HOME/config"
SECRETS_FILE="$POLYSBX_CONFIG_HOME/secrets.env"

# ── Logging (everything to stderr; stdout is reserved for data) ─────────────
info() { printf '▶ %s\n'  "$*" >&2; }
warn() { printf '⚠️  %s\n' "$*" >&2; }
err()  { printf '❌ %s\n'  "$*" >&2; }
die()  { err "$*"; exit 1; }

# ── Platform detection ──────────────────────────────────────────────────────
detect_os()   { case "$(uname -s)" in Darwin) echo macos;; Linux) echo linux;; *) echo unknown;; esac; }
detect_arch() { case "$(uname -m)" in x86_64|amd64) echo amd64;; arm64|aarch64) echo arm64;; *) echo unknown;; esac; }

# Effective UID/GID to bake into / run the image as. We never run as root inside
# the container — if the host user is root, fall back to 1000.
effective_uid() { local u; u="$(id -u)"; [[ "$u" == 0 ]] && echo 1000 || echo "$u"; }
effective_gid() { if [[ "$(id -u)" == 0 ]]; then echo 1000; else id -g; fi; }

# ── Config / secrets ────────────────────────────────────────────────────────
load_config() {
    [[ -f "$CONFIG_FILE" ]] || die "no config at $CONFIG_FILE — run: psb init"
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    : "${BACKEND:=docker}"
    : "${AUTH_MODE:=subscription}"      # subscription | apikey | token
    : "${LANGUAGES:=}"                  # space-separated: dotnet go python rust
    : "${CONFIG_DIR:=$HOME/.claude}"
    : "${ADO_ENABLED:=0}"
    : "${GH_ENABLED:=0}"
    : "${DENY_MERGE:=0}"
    : "${SETTINGS_EXAMPLE:=0}"
    : "${IMAGE_TAG:=polysbx:latest}"
    : "${MEMORY:=8g}"
    : "${CPUS:=4}"
    : "${PIDS:=256}"
    : "${NET_MODE:=open}"               # open | allowlist  (allowlist is sbx/msbx; docker is open in P0)
    # Expand a leading ~ in CONFIG_DIR.
    CONFIG_DIR="${CONFIG_DIR/#\~/$HOME}"
    export BACKEND AUTH_MODE LANGUAGES CONFIG_DIR ADO_ENABLED GH_ENABLED \
           DENY_MERGE SETTINGS_EXAMPLE IMAGE_TAG MEMORY CPUS PIDS NET_MODE
}

load_secrets() {
    [[ -f "$SECRETS_FILE" ]] || return 0
    # shellcheck disable=SC1090
    set -a; source "$SECRETS_FILE"; set +a
}

# Project = git worktree root if available, else cwd.
resolve_project_dir() {
    if git rev-parse --show-toplevel >/dev/null 2>&1; then
        git rev-parse --show-toplevel
    else
        pwd
    fi
}

# ── Self-update ─────────────────────────────────────────────────────────────
polysbx_update() {
    if git -C "$POLYSBX_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        info "Updating polysbx ($POLYSBX_ROOT)…"
        git -C "$POLYSBX_ROOT" pull --ff-only
        info "Updated. If the image template or modules changed, rebuild: psb build"
    else
        warn "polysbx is not a git checkout ($POLYSBX_ROOT) — nothing to update."
    fi
}
