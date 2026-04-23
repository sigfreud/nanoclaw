#!/bin/bash
# Recover NanoClaw after a reboot, outage, or stuck state.
#
# Idempotent: safe to re-run. Checks each dependency, fixes what it can,
# fails loudly with an actionable message for anything it can't.
#
# Invocation from *inside* WSL:
#   bash scripts/recover-nanoclaw.sh
#
# Invocation from a Windows shell (e.g. via Tailscale SSH into Windows,
# or via RDP + Windows Terminal):
#   wsl.exe -d Ubuntu --user sigfreud bash /home/sigfreud/projects/nanoclaw/scripts/recover-nanoclaw.sh
#
# Exit code 0 = nanoclaw.service is active and processing. Non-zero = action needed.

set -uo pipefail

REPO_DIR="${NANOCLAW_DIR:-$HOME/projects/nanoclaw}"
DOCKER_DESKTOP_PATH='C:\Program Files\Docker\Docker\Docker Desktop.exe'
DOCKER_POLL_TIMEOUT=120   # seconds to wait for Docker engine after launch
SERVICE_POLL_TIMEOUT=30   # seconds to wait for nanoclaw.service to go active

log()  { printf '[%(%H:%M:%S)T] %s\n' -1 "$*"; }
die()  { log "FAIL: $*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# --- 1. Environment sanity ----------------------------------------------------

[[ -d "$REPO_DIR" ]] || die "NanoClaw repo not found at $REPO_DIR (override with NANOCLAW_DIR=…)"
have systemctl      || die "systemctl missing — is systemd enabled in /etc/wsl.conf?"
have docker         || die "docker CLI not on PATH — is Docker Desktop's WSL integration enabled for this distro?"
have powershell.exe || log "WARN: powershell.exe not on PATH — cannot launch Docker Desktop from here. Will fail if Docker is down."

# --- 2. User systemd bus ------------------------------------------------------
# Without linger (or an active PAM session), systemctl --user has no bus to talk to.

if ! systemctl --user list-units --type=service --no-pager >/dev/null 2>&1; then
  die "User systemd bus unreachable. Fixes:
  - Enable linger once: sudo loginctl enable-linger \$USER
  - Or invoke this script via 'wsl.exe -d Ubuntu --user \$USER bash …' from Windows so PAM creates a session.
  - Verify: 'systemctl --user list-units' should succeed."
fi

# --- 3. Docker runtime --------------------------------------------------------

if docker info >/dev/null 2>&1; then
  log "Docker runtime up ($(docker info --format '{{.ServerVersion}}' 2>/dev/null || echo '?'))"
else
  log "Docker runtime down — launching Docker Desktop via WSL interop…"
  if have powershell.exe; then
    powershell.exe -NoProfile -Command "Start-Process -FilePath \"$DOCKER_DESKTOP_PATH\"" \
      >/dev/null 2>&1 || log "WARN: Start-Process returned non-zero (may still have launched)"
  fi

  log "Polling docker info for up to ${DOCKER_POLL_TIMEOUT}s…"
  deadline=$(( $(date +%s) + DOCKER_POLL_TIMEOUT ))
  while ! docker info >/dev/null 2>&1; do
    (( $(date +%s) < deadline )) || die "Docker never came up.
If running via SSH-into-Windows with nobody logged in at the console,
Docker Desktop may refuse to launch without an interactive desktop session.
Workarounds: (a) set Docker Desktop autoStart=true so Windows boot brings it up,
(b) RDP into Windows once to establish an interactive session, or
(c) log in at the console."
    sleep 3
  done
  log "Docker runtime came up"
fi

# --- 4. NanoClaw service ------------------------------------------------------

current_state="$(systemctl --user is-active nanoclaw.service 2>/dev/null || true)"
log "nanoclaw.service current state: ${current_state:-unknown}"

# Always restart: cheap, and heals any stuck/degraded state.
# reset-failed clears the restart counter if it's been crash-looping.
systemctl --user reset-failed nanoclaw.service 2>/dev/null || true
systemctl --user restart nanoclaw.service

log "Waiting up to ${SERVICE_POLL_TIMEOUT}s for service to reach active…"
deadline=$(( $(date +%s) + SERVICE_POLL_TIMEOUT ))
while [[ "$(systemctl --user is-active nanoclaw.service 2>/dev/null)" != "active" ]]; do
  if (( $(date +%s) >= deadline )); then
    systemctl --user status nanoclaw.service --no-pager 2>&1 | head -20
    die "nanoclaw.service did not reach active. Check logs: tail -100 $REPO_DIR/logs/nanoclaw.error.log"
  fi
  sleep 2
done
log "nanoclaw.service is active"

# --- 5. Confirm healthy boot from log ----------------------------------------

log "Recent log (filtered):"
tail -60 "$REPO_DIR/logs/nanoclaw.log" 2>/dev/null \
  | grep -vE 'DeprecationWarning|trace-deprecation' \
  | tail -15 \
  || log "WARN: could not read $REPO_DIR/logs/nanoclaw.log"

# Heuristic: something like "NanoClaw running" should appear after a clean boot.
if tail -200 "$REPO_DIR/logs/nanoclaw.log" 2>/dev/null | grep -q "NanoClaw running"; then
  log "Startup banner found — recovery complete."
  exit 0
else
  log "Service is active but no 'NanoClaw running' banner yet. Give it another ~10s and re-check if needed."
  exit 0
fi
