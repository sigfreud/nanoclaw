# NanoClaw

Personal Claude assistant. See [README.md](README.md) for philosophy and setup. See [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md) for architecture decisions.

## Quick Context

Single Node.js process with skill-based channel system. Channels (WhatsApp, Telegram, Slack, Discord, Gmail) are skills that self-register at startup. Messages route to Claude Agent SDK running in containers (Linux VMs). Each group has isolated filesystem and memory.

## Key Files

| File | Purpose |
|------|---------|
| `src/index.ts` | Orchestrator: state, message loop, agent invocation |
| `src/channels/registry.ts` | Channel registry (self-registration at startup) |
| `src/ipc.ts` | IPC watcher and task processing |
| `src/router.ts` | Message formatting and outbound routing |
| `src/config.ts` | Trigger pattern, paths, intervals |
| `src/container-runner.ts` | Spawns agent containers with mounts |
| `src/task-scheduler.ts` | Runs scheduled tasks |
| `src/db.ts` | SQLite operations |
| `groups/{name}/CLAUDE.md` | Per-group memory (isolated) |
| `container/skills/agent-browser.md` | Browser automation tool (available to all agents via Bash) |

## Skills

| Skill | When to Use |
|-------|-------------|
| `/setup` | First-time installation, authentication, service configuration |
| `/customize` | Adding channels, integrations, changing behavior |
| `/debug` | Container issues, logs, troubleshooting |
| `/update-nanoclaw` | Bring upstream NanoClaw updates into a customized install |
| `/qodo-pr-resolver` | Fetch and fix Qodo PR review issues interactively or in batch |
| `/get-qodo-rules` | Load org- and repo-level coding rules from Qodo before code tasks |

## Development

Run commands directly—don't tell the user to run them.

```bash
npm run dev          # Run with hot reload
npm run build        # Compile TypeScript
./container/build.sh # Rebuild agent container
```

Service management:
```bash
# macOS (launchd)
launchctl load ~/Library/LaunchAgents/com.nanoclaw.plist
launchctl unload ~/Library/LaunchAgents/com.nanoclaw.plist
launchctl kickstart -k gui/$(id -u)/com.nanoclaw  # restart

# Linux (systemd)
systemctl --user start nanoclaw
systemctl --user stop nanoclaw
systemctl --user restart nanoclaw
```

## Troubleshooting

**WhatsApp not connecting after upgrade:** WhatsApp is now a separate channel fork, not bundled in core. Run `/add-whatsapp` (or `git remote add whatsapp https://github.com/qwibitai/nanoclaw-whatsapp.git && git fetch whatsapp main && (git merge whatsapp/main || { git checkout --theirs package-lock.json && git add package-lock.json && git merge --continue; }) && npm run build`) to install it. Existing auth credentials and groups are preserved.

## OAuth Token Refresh (Claude Max)

When using Claude Max (consumer OAuth) instead of an API key, tokens expire every ~24 hours. Three safety nets keep them fresh:

| Layer | Mechanism | Trigger |
|-------|-----------|---------|
| systemd timer | `scripts/refresh-oauth-token.sh` | Every 6 hours (`nanoclaw-token-refresh.timer`) |
| Proxy proactive | `src/credential-proxy.ts` spawns refresh script | Token <1 hour from expiry |
| Manual | `bash scripts/refresh-oauth-token.sh` | Run anytime |

**How it works:** The credential proxy (`src/credential-proxy.ts`) re-reads `~/.claude/.credentials.json` on every request. Containers never see real tokens — they send placeholders that the proxy swaps for the real OAuth token before forwarding to Anthropic.

**Check token state:**
```bash
python3 -c "import json,time; c=json.load(open('$HOME/.claude/.credentials.json')); print(f'{(c[\"claudeAiOauth\"][\"expiresAt\"]-time.time()*1000)/3600000:.1f}h remaining')"
```

**Force refresh:**
```bash
bash scripts/refresh-oauth-token.sh
```

**If both strategies in the script fail:**
1. Check `systemctl --user status nanoclaw-token-refresh` for errors
2. Try `claude -p "hi" --max-turns 1` to trigger CLI-internal refresh
3. As last resort: `claude` login flow to get a fresh token

## Container Build Cache

The container buildkit caches the build context aggressively. `--no-cache` alone does NOT invalidate COPY steps — the builder's volume retains stale files. To force a truly clean rebuild, prune the builder then re-run `./container/build.sh`.
