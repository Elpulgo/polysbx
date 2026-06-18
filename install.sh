#!/usr/bin/env bash
# polysbx installer. Run locally from a checkout, or piped from curl:
#   curl -fsSL https://raw.githubusercontent.com/elpulgo/polysbx/main/install.sh | bash
set -euo pipefail

# polysbx runs Claude Code inside a Linux container, so it needs a macOS or Linux
# host. Refuse native Windows (Git Bash/MSYS/Cygwin) before cloning or running
# anything. WSL2 reports as Linux and is supported — run polysbx from there.
case "$(uname -s)" in
    Darwin|Linux) ;;
    MINGW*|MSYS*|CYGWIN*)
        echo "❌ polysbx does not support Windows — it runs Claude Code in a Linux container and needs a macOS or Linux host." >&2
        echo "   On Windows, install WSL2 and run this installer from inside the WSL (Linux) shell:" >&2
        echo "     https://learn.microsoft.com/windows/wsl/install" >&2
        exit 1 ;;
esac

REPO_URL="${POLYSBX_REPO:-https://github.com/elpulgo/polysbx.git}"
DEST="${POLYSBX_DEST:-${XDG_DATA_HOME:-$HOME/.local/share}/polysbx}"

# Resolve our own directory. CDPATH= and -- guard against a user's exported
# CDPATH or odd argv from breaking the cd; fall back to $0 when not sourced.
here="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
# Detect a checkout by the harness's *existence*, not its exec bit — the bit is
# routinely dropped by zip transfers, some editors, and non-preserving mounts.
if [[ -n "$here" && -f "$here/bin/claude-harness" ]]; then
    root="$here"                                   # running from a checkout
else
    command -v git >/dev/null || { echo "❌ git is required to fetch polysbx" >&2; exit 1; }
    if [[ -d "$DEST/.git" ]]; then
        echo "▶ Updating polysbx in $DEST" >&2
        GIT_TERMINAL_PROMPT=0 git -C "$DEST" pull --ff-only
    else
        echo "▶ Cloning polysbx into $DEST" >&2
        # GIT_TERMINAL_PROMPT=0: if the repo isn't published (or is private),
        # fail loudly instead of popping a GitHub sign-in prompt.
        GIT_TERMINAL_PROMPT=0 git clone --depth 1 "$REPO_URL" "$DEST" || {
            echo "❌ Could not clone $REPO_URL — if you have a local checkout, run ./install.sh from inside it." >&2
            exit 1
        }
    fi
    root="$DEST"
fi

# Self-heal the exec bit so future invocations and the psb shim work regardless.
chmod +x "$root/bin/claude-harness" 2>/dev/null || true
# Invoke via bash so a missing exec bit can't block us.
exec bash "$root/bin/claude-harness" init "$@"
