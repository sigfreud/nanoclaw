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
| `src/container-runtime.ts` | Runtime abstraction. `ensureContainerRuntimeRunning` auto-launches Docker Desktop on WSL if the runtime is down |
| `scripts/recover-nanoclaw.sh` | Idempotent one-shot recovery after outage / stuck state |
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

**Crash loop / service won't stay up:** See [Auto-start & Recovery](#auto-start--recovery) below. The most common cause on WSL is Docker Desktop being stopped; the service now auto-launches it, but if that fails run `bash scripts/recover-nanoclaw.sh`.

## Auto-start & Recovery

NanoClaw is built to come back up on its own after a reboot or outage. The moving parts:

| Layer | Setting | Why it matters |
|-------|---------|----------------|
| Windows | Docker Desktop `autoStart: true` in `%APPDATA%\Docker\settings.json` | Engine is up before the service probes it; avoids triggering the in-code fallback on every boot |
| WSL | `loginctl Linger=yes` for the user | User systemd (and `nanoclaw.service`) runs without an active terminal session — survives SSH disconnect |
| systemd | `nanoclaw.service` + `nanoclaw-token-refresh.timer` enabled | Service starts with the user slice and restarts on crash (`Restart=always`) |
| Code | `ensureContainerRuntimeRunning()` in `src/container-runtime.ts` | On WSL, if `docker info` fails, launches Docker Desktop via `powershell.exe Start-Process` and polls for up to 90s before giving up |

**Check it all at once:**
```bash
systemctl --user is-active nanoclaw.service          # expect: active
loginctl show-user "$USER" --property=Linger          # expect: Linger=yes
docker info --format '{{.ServerVersion}}'             # expect: a version string
grep -oE '"autoStart":\s*(true|false)' "/mnt/c/Users/$(whoami)/AppData/Roaming/Docker/settings.json"
```

**Force recovery (safe to re-run at any time):**
```bash
bash scripts/recover-nanoclaw.sh
```

Idempotent. Probes Docker → launches Docker Desktop if down → waits → restarts `nanoclaw.service` → tails the log for the `NanoClaw running` banner. Works from inside WSL, or from a Windows shell via `wsl.exe -d Ubuntu --user $USER bash /path/to/script`.

**Remote SSH access over Tailscale (how it actually works on this host):** Tailscale SSH *server* is Linux-only, and Windows OpenSSH Server is NOT installed here (`Get-WindowsCapability -Online -Name OpenSSH.Server*` → `NotPresent`). Instead, SSH lands inside WSL via a port-forward:

1. **WSL sshd** runs inside the Ubuntu distro, started by `/etc/wsl.conf` → `[boot] command=service ssh start` (SysV init) **and** redundantly by a Windows Task Scheduler task `StartWSL` (`wsl.exe -d Ubuntu -u root -- service ssh start`, trigger: at logon, RunLevel Highest).
2. **Windows `netsh interface portproxy`** forwards `0.0.0.0:22 → 172.19.201.207:22` (WSL's `eth0`). Rule is persistent in the registry.
3. **Windows firewall rule** `SSH for WSL` (inbound, Allow, all profiles) lets the connection reach the portproxy.
4. **Tailscale on Windows** (`100.110.29.28 laptop-l5ic913g`) provides the routable IP — from any tailnet peer, `ssh sigfreud@100.110.29.28` is transparently NAT'd to Windows:22 → WSL:22.

**Quirks worth remembering:**
- `systemd ssh.socket` fails every boot with *"Address already in use"* because the SysV `service ssh start` grabbed port 22 first. Harmless — sshd is already running. Don't "fix" it by disabling the SysV path; the socket unit is known-broken in this config.
- Inside an SSH session `SSH_CLIENT` shows `172.19.192.1` (the Windows vEthernet (WSL) adapter), **not the real remote IP** — side effect of the portproxy. Don't use it for audit/security decisions.
- The portproxy destination is hardcoded to `172.19.201.207`. WSL's eth0 IP has been stable across reboots on this host, but a WSL update that changes the default subnet would silently break remote SSH until the rule is re-added (`netsh interface portproxy add v4tov4 listenport=22 listenaddress=0.0.0.0 connectport=22 connectaddress=<new-wsl-ip>`).
- To inspect: `netsh interface portproxy show all` (from Windows/PowerShell), `ss -tlnp | grep :22` (from WSL).

**Known limitation:** Docker Desktop sometimes refuses to launch from a non-interactive SSH session when no one is logged into the Windows console. If `powershell.exe Start-Process "Docker Desktop.exe"` returns 0 but `docker info` never succeeds inside the poll window, the fix is either (a) RDP in once to establish an interactive desktop, or (b) ensure `autoStart: true` so Docker comes up with Windows boot before anyone connects.

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
