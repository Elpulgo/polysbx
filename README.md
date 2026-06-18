# polysbx

Run **Claude Code inside a sandbox** with one command. Pick your isolation
backend (Docker, [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/), or
[microsandbox](https://microsandbox.dev)), your auth (subscription / API key /
token), and which language toolchains go in the image — polysbx onboards you and
gives you a `psb` command that works in any repo.

> **Status:** Phase 3 — all three backends (**docker**, **msbx**, **sbx**) are
> wired end-to-end, with multiselect onboarding, all four language modules, and a
> verifying `doctor`. `msbx` (microsandbox) is beta (needs Apple Silicon or
> Linux+KVM); `sbx` (Docker Sandboxes) is beta (host-keychain auth via `sbx login`,
> no OAuth-token mode). See [`SPEC.md`](./SPEC.md).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/elpulgo/polysbx/main/install.sh | bash
# or, from a checkout:
./install.sh
```

`install.sh` runs `psb init`, which:

1. detects your OS/arch and checks prerequisites (**detect-and-instruct only — it
   never installs anything for you**);
2. asks for backend, auth mode, languages, your Claude config dir, and optional
   Azure DevOps / GitHub integrations;
3. builds the toolchain image with just the modules you chose;
4. runs a one-time Claude login (subscription mode);
5. drops a `psb` shim on `~/.local/bin`.

## Use

```bash
cd ~/some/project
psb                      # launch Claude in the sandbox (default subcommand)
psb "fix the failing test in pkg/foo"
psb doctor               # verify the install
psb build                # rebuild the image (after changing languages)
psb setup-auth           # re-login (subscription)
psb clean                # reclaim image + volumes/sandboxes
psb clean --all          # (sbx) also stop + remove running instances
psb update               # git-pull polysbx itself (re-run `psb build` after)
```

## Backends

All three share the onboarding, language modules, config model, and `psb`
surface; they differ in the isolation boundary and where credentials live.

| Backend | Isolation | Image base | Auth (subscription) | Status |
|---|---|---|---|---|
| `docker` | hand-rolled hardening (cap-drop, read-only, tmpfs, limits) | Debian + Node + Claude Code | login → `polysbx-auth` volume | validated |
| `msbx`  | microVM (microsandbox/libkrun) | same Debian base, `docker save \| msb load` | login → cache-home dir | beta — Apple Silicon or Linux+KVM |
| `sbx`   | Docker Sandboxes VM | `docker/sandbox-templates:claude-code` + modules | `sbx login` (host-keychain proxy) | beta — no OAuth-token mode |

## How it works (the short version)

- **Image** = your base + Node + Claude Code + the language modules you picked
  (`.NET 8/10`, `Go`, `Python`, `Rust`) + optional `azure-cli` / `gh`. Built once,
  UID/GID baked in so bind-mounts line up on Linux and macOS. `docker`/`msbx` use
  a Debian base; `sbx` layers the same modules onto Docker's Claude-Code template.
- **Two state locations, kept separate:**
  - a **managed home** holding your **credentials + session state** — you log in
    once. It's a Docker volume (`docker`), a cache-home dir (`msbx`), or the
    host-keychain proxy (`sbx`).
  - your **config dir** (default `~/.claude`), read-only, from which polysbx
    stages the known subpaths (`skills agents commands hooks rules settings.json`)
    into a polysbx-owned copy. Your config dir is never written to, and your
    credentials never enter the config mount.
- **Hardening:** for `docker`, `--cap-drop=ALL`, `--read-only`,
  `--no-new-privileges`, tmpfs scratch, and resource limits; for `msbx`/`sbx` the
  (micro)VM boundary subsumes that. All backends keep the behavioural guardrails
  (opt-in deny-list, protected-branch pre-push hook) and run Claude with
  `--dangerously-skip-permissions` (the sandbox *is* the boundary).
- **Network egress:** `NET_MODE=allowlist` restricts the sandbox to a per-backend
  allow-list derived from your selected toolchains (`open` by default).

## Config

Lives at `~/.config/polysbx/`:

- `config` — backend, auth mode, languages, config dir, integrations, limits
  (see [`templates/config.example`](./templates/config.example)).
- `secrets.env` (`chmod 600`) — `ANTHROPIC_API_KEY` **or** `CLAUDE_CODE_OAUTH_TOKEN`
  (only in api/token modes; subscription stores nothing here), plus
  `AZURE_DEVOPS_EXT_PAT` / `GITHUB_TOKEN` when those integrations are on.

Edit either and re-run `psb` (config is re-staged each launch) or `psb build`
(after changing languages).

## Known limitations

### `msbx`: `Input/output error` on a file inside the sandbox (virtiofs cache)

On the `msbx` backend the project is shared into the microVM over **virtiofs**.
Git normally works fine inside the sandbox (commits included). But if you mutate
the **same file from the host while the sandbox is running** — e.g. commit from a
host terminal, or run another tool (another agent, an editor, `git gc`) against
the same `.git` — the guest can be left holding a stale cache entry for a file
whose inode the host just replaced. Many git operations rewrite a file by writing
a temp file and `rename()`-ing it over the original (`.git/config`, refs, the
index), which swaps the inode and trips this. The symptom is a single file going
`Input/output error`, vanishing from `ls` **inside** the sandbox, while the
**host reads it fine**. It is not corruption and not a missing mount — the whole
repo is mapped correctly; it's a virtiofs metadata-cache coherence limitation of
the microVM runtime (one reason `msbx` is beta), and `msb run` exposes no cache
mode to tune it away.

**Recover:** exit Claude and relaunch `psb` — a fresh microVM gets a fresh
virtiofs session and re-reads the file from the host.

**Avoid:** don't drive git (or another tool that writes `.git`) against the same
repo from the host while an `msbx` session is live. Commit from inside the
sandbox *or* the host, not both at once.
