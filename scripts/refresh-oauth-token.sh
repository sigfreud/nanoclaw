#!/bin/bash
# Refresh the Claude OAuth token for NanoClaw.
# Uses two strategies:
#   1. Direct API call to platform.claude.com/v1/oauth/token (fast, no token usage)
#   2. Fallback: run `claude -p "hi"` which triggers internal token refresh
#
# Run via systemd timer every 6 hours to keep the token fresh.

set -uo pipefail

CREDS_FILE="$HOME/.claude/.credentials.json"
CLIENT_ID="9d1c250a-e61b-44d9-88ed-5944d1962f5e"
TOKEN_URL="https://platform.claude.com/v1/oauth/token"
SCOPES="user:inference user:profile user:sessions:claude_code user:mcp_servers user:file_upload"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [refresh-token] $*"; }

if [ ! -f "$CREDS_FILE" ]; then
  log "ERROR: $CREDS_FILE not found"
  exit 1
fi

# Check if token actually needs refresh (skip if >2 hours remaining)
EXPIRES_AT=$(python3 -c "import json; print(json.load(open('$CREDS_FILE'))['claudeAiOauth']['expiresAt'])")
NOW_MS=$(python3 -c "import time; print(int(time.time() * 1000))")
REMAINING_MS=$((EXPIRES_AT - NOW_MS))
REMAINING_HOURS=$(python3 -c "print(f'{$REMAINING_MS / 3600000:.1f}')")

if [ "$REMAINING_MS" -gt 7200000 ]; then
  log "Token still valid for ${REMAINING_HOURS}h, skipping refresh"
  exit 0
fi

log "Token expires in ${REMAINING_HOURS}h, refreshing..."

REFRESH_TOKEN=$(python3 -c "import json; print(json.load(open('$CREDS_FILE'))['claudeAiOauth']['refreshToken'])")

if [ -z "$REFRESH_TOKEN" ]; then
  log "ERROR: No refresh token found"
  exit 1
fi

# Strategy 1: Direct API refresh (with one retry on rate limit)
try_api_refresh() {
  local RESPONSE
  RESPONSE=$(curl -s -X POST "$TOKEN_URL" \
    -H "Content-Type: application/json" \
    -d "{\"grant_type\":\"refresh_token\",\"refresh_token\":\"$REFRESH_TOKEN\",\"client_id\":\"$CLIENT_ID\",\"scope\":\"$SCOPES\"}" 2>&1)

  if echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if 'access_token' in d else 1)" 2>/dev/null; then
    python3 << PYEOF
import json, time

response = json.loads('''$RESPONSE''')
with open('$CREDS_FILE', 'r') as f:
    creds = json.load(f)

creds['claudeAiOauth']['accessToken'] = response['access_token']
if 'refresh_token' in response:
    creds['claudeAiOauth']['refreshToken'] = response['refresh_token']
expires_in = response.get('expires_in', 86400)
creds['claudeAiOauth']['expiresAt'] = int(time.time() * 1000) + (expires_in * 1000)

with open('$CREDS_FILE', 'w') as f:
    json.dump(creds, f)

print(f'Token refreshed via API. Expires in {expires_in/3600:.1f} hours.')
PYEOF
    return 0
  fi

  echo "$RESPONSE"
  return 1
}

if try_api_refresh; then
  log "Strategy 1 (API) succeeded"
  exit 0
fi

# If rate-limited, wait and retry once
if echo "$RESPONSE" 2>/dev/null | grep -q "rate_limit"; then
  log "Rate limited, retrying in 30s..."
  sleep 30
  if try_api_refresh; then
    log "Strategy 1 (API) succeeded on retry"
    exit 0
  fi
fi

log "Strategy 1 (API) failed, trying strategy 2 (claude CLI)..."

# Strategy 2: Run claude CLI which handles refresh internally
if command -v claude &>/dev/null; then
  claude -p "token refresh ping" --max-turns 1 --output-format text &>/dev/null || true

  # Verify token was refreshed
  NEW_EXPIRES=$(python3 -c "import json; print(json.load(open('$CREDS_FILE'))['claudeAiOauth']['expiresAt'])")
  if [ "$NEW_EXPIRES" -gt "$EXPIRES_AT" ]; then
    NEW_HOURS=$(python3 -c "import json,time; e=json.load(open('$CREDS_FILE'))['claudeAiOauth']['expiresAt']; print(f'{(e-time.time()*1000)/3600000:.1f}')")
    log "Strategy 2 (CLI) succeeded. New expiry in ${NEW_HOURS}h"
    exit 0
  fi
  log "Strategy 2 ran but token expiry unchanged"
fi

log "ERROR: All refresh strategies failed"
exit 1
