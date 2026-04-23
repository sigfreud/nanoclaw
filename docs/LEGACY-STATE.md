# Legacy State — pre-OneCLI upgrade (snapshot 2026-04-23)

This file lives only on the `legacy/pre-onecli-upgrade` branch. Its purpose is to let a future operator (human or Claude) fully understand what this fork was *before* the OneCLI canonical migration, and roll back to it quickly if needed.

## Why this branch exists

On 2026-04-23 at 02:30:56 CST, a scheduled NanoClaw task failed with an Anthropic 401 (`req_011CaLPcWgpKWu6uE1UczDF7`). Investigation showed the custom OAuth auto-refresh mechanism (credential proxy + shell script + systemd timer) has structural bugs, and upstream NanoClaw has since moved to a fundamentally different credential architecture (OneCLI Agent Vault). Rather than fix the custom code, we're migrating to the canonical upstream path.

Full diagnosis + multi-phase migration plan: `~/.claude/plans/hi-there-staged-lemur.md` (private, not in repo).

## Git position at snapshot

- **Branch:** `legacy/pre-onecli-upgrade`
- **Tag:** `pre-onecli-upgrade-2026-04-23`
- **Relative to `upstream/main`:** 57 commits ahead, 702 behind
- **Tip commit of `main` at snapshot time:** `e671745` (`docs: correct remote SSH access section with actual setup`)

## What's custom on this fork (not in upstream)

These are the files/paths that the canonical upstream either doesn't ship, or removed — and that this fork depends on.

### Custom OAuth auto-refresh (the reason for the upgrade)
- `src/credential-proxy.ts` — upstream deleted this at commit `14247d0` (2026-03-24); here it remains active.
- `scripts/refresh-oauth-token.sh` — local addition; no upstream equivalent.
- `~/.config/systemd/user/nanoclaw-token-refresh.service` — local systemd unit.
- `~/.config/systemd/user/nanoclaw-token-refresh.timer` — fires every 6h.

### WSL-specific hardening
- `src/container-runtime.ts` — includes `ensureContainerRuntimeRunning()` which auto-launches Docker Desktop via `powershell.exe Start-Process` if the runtime is down. Cold-boot test 2026-04-22 confirmed this is load-bearing on WSL and must survive any merge.
- `scripts/recover-nanoclaw.sh` — idempotent outage-recovery script. Not in upstream.

### Forks (channel skills applied on top of base)
- `telegram` remote → `https://github.com/qwibitai/nanoclaw-telegram.git`
- `whatsapp` remote → `https://github.com/qwibitai/nanoclaw-whatsapp.git`
- `gmail` remote → `https://github.com/qwibitai/nanoclaw-gmail.git` (being **removed** in the upgrade)

### Installed services and supporting files
- `nanoclaw.service` (user systemd, `Restart=always`)
- `nanoclaw-token-refresh.timer` + `.service` (deleted in Phase 4 of the upgrade)
- `loginctl Linger=yes` for user `sigfreud`
- Windows: Docker Desktop with `autoStart: true` in `%APPDATA%\Docker\settings.json`
- Windows Task Scheduler `StartWSL` (root SysV `service ssh start` trigger at logon)
- Windows `netsh interface portproxy` rule: `0.0.0.0:22 → 172.19.201.207:22`

## Known bugs in this state (all fixed by migrating, not patching)

From the 2026-04-23 incident diagnosis:

1. **`src/credential-proxy.ts:53–57`** — proactive refresh is asynchronous; the same request returns the stale token before refresh completes, so the first call after expiry is guaranteed to 401.
2. **`scripts/refresh-oauth-token.sh:82–89`** — rate-limit retry block references `$RESPONSE` outside its declaring function scope. Under `set -u` it is effectively dead code; the script always falls straight to Strategy 2 after a single API failure.
3. **Three uncoordinated writers** on `~/.claude/.credentials.json`: `refresh-oauth-token.sh`, its own spawned `claude -p` (Strategy 2), and the operator's interactive `claude` in tmux. No `flock`, no atomic writes. Torn reads, refresh-token rotation races, cumulative rate-limits on `/v1/oauth/token`.
4. **Skip threshold (2h) < timer interval (6h)** — the timer can land 3h past expiry if a fire-time happens at 3h-remaining.
5. **No `OnFailure=` on the refresh service** — a single failure blinds the system for a full 6h cycle. That's the window the 02:30 incident landed in.

## Stateful data snapshot — outside the repo

All mutable state that is not tracked in git was archived before the upgrade. Do NOT rely on working-tree contents for rollback; use the archive.

- **Path:** `/home/sigfreud/nanoclaw-state-backup-2026-04-23/`
- **Size:** 26 MB
- **Contents:**
  - `messages.db` — hot-consistent SQLite backup via `sqlite3.Connection.backup()` (Python). 204 KB.
  - `whatsapp-auth/` — full Baileys auth directory from `store/auth/` (1836 files).
  - `groups/` — all per-group state and memory files.
  - `env-snapshot` — copy of `.env` at snapshot time.
  - `MANIFEST.sha256` — per-file sha256 of all 2161 files.
- **Manifest rollup sha256:** `c944d14638851dc178ef1057436fac0ccce6807a01bdc41a0b102cf05b1c29b0`

Per-group CLAUDE.md presence at snapshot:
- `global` — 77 lines
- `main` — 250 lines (primary context payload)
- `telegram_main` — 53 lines
- `telegram_noctua-swarm` — none (empty memory)
- `whatsapp_main` — none (empty memory)

Empty-memory groups' historical context (if needed) can be reconstructed from `messages.db` in the archive.

## Rollback procedure (from any future state back to this snapshot)

```bash
# Assuming the current main has diverged and you want to fully revert:
systemctl --user stop nanoclaw.service
cd ~/projects/nanoclaw
git fetch origin
git switch main
git reset --hard legacy/pre-onecli-upgrade

# Restore stateful data from archive:
cp -a ~/nanoclaw-state-backup-2026-04-23/messages.db store/
cp -a ~/nanoclaw-state-backup-2026-04-23/whatsapp-auth/* store/auth/
cp -a ~/nanoclaw-state-backup-2026-04-23/groups/ .
cp ~/nanoclaw-state-backup-2026-04-23/env-snapshot .env

npm install
npm run build
systemctl --user daemon-reload
systemctl --user enable --now nanoclaw-token-refresh.timer
systemctl --user start nanoclaw.service

# Verify:
systemctl --user status nanoclaw.service
journalctl --user -u nanoclaw.service -n 50 --no-pager
```

Expect to be back on the legacy stack in under 5 minutes. The known bugs listed above will still be present — this rollback restores working behavior, not a fixed version.

## Credentials file at snapshot

- Path: `~/.claude/.credentials.json`
- Shape: `{ "claudeAiOauth": { "accessToken": "...", "refreshToken": "...", "expiresAt": <epoch_ms> } }`
- Not in the archive (live-mutating; always read current when rolling back).

## Contact / audit trail

- Snapshot author: sigfreud (with Claude Code assistance, session 2026-04-23 ~12:10 CST)
- Full conversation/plan: `~/.claude/plans/hi-there-staged-lemur.md`
- Upstream reference commit (for the architecture we're migrating to): `14247d0` (`skill: add /use-native-credential-proxy, remove dead proxy code`)
