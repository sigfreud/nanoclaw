---
name: add-granola
description: Install the Granola integration into a NanoClaw agent group via the official OAuth MCP server (mcp.granola.ai), bridged stdio↔HTTP with mcp-remote. Script-mediated by design — the agent never sees Granola MCP tools directly. Idempotent.
---

# Add Granola Integration

Wires Granola access (meetings, transcripts, folders, calendar events, shared docs) into an agent group using the **official** Granola MCP server `https://mcp.granola.ai/mcp` (OAuth 2.0 + Dynamic Client Registration + PKCE). The bridge is the `mcp-remote` npm package because NanoClaw only supports stdio MCP servers.

**Why not `granola-mcp-plus`:** that package reads WorkOS access tokens from the desktop app's `supabase.json`, which expires every 6 hours and races against Granola desktop on the same account if both try to refresh. The official OAuth path issues independent tokens per MCP client — Granola desktop on Windows/Mac stays usable in parallel without disturbing the agent's tokens.

**Why script-mediated:** per NanoClaw best practice, Granola MCP tools are **not** declared in `mcpServers`. Interaction goes through a curated wrapper script (`groups/<folder>/scripts/granola.sh`) that spawns `mcp-remote` per call and returns filtered JSON. This keeps agent context lean and isolates the agent from MCP-side changes.

## Pin

This skill targets `mcp-remote@0.1.38`. Update path: bump every reference in this file, the in-container skill (`container/skills/granola/SKILL.md`), and any installed `granola.sh`. Token cache files are versioned (`~/.mcp-auth/mcp-remote-<VERSION>/`) so a version change requires a re-bootstrap.

## Phase 1: Pre-flight (host)

### 1.1 Mount allowlist

`mcp-remote` writes OAuth tokens to `~/.mcp-auth/`. The host mount-allowlist must permit it:

```bash
cat ~/.config/nanoclaw/mount-allowlist.json
```

`/home/<user>/.mcp-auth` must be in `allowedRoots` with `allowReadWrite: true`. Add it if missing:

```json
{
  "allowedRoots": [
    {
      "path": "/home/<user>/.mcp-auth",
      "allowReadWrite": true,
      "description": "mcp-remote OAuth token cache for remote MCPs"
    }
  ],
  "blockedPatterns": [],
  "nonMainReadOnly": true
}
```

Restart the NanoClaw host after editing (`loadMountAllowlist()` caches in memory).

### 1.2 Token cache dir

```bash
mkdir -p ~/.mcp-auth
```

## Phase 2: One-time OAuth bootstrap (host)

Run from the host shell (not from inside any container). On WSL2, this needs Windows-side localhost forwarding (default-on; see fallback below).

```bash
HOME=$HOME npx -y mcp-remote@0.1.38 https://mcp.granola.ai/mcp 3334 --host 127.0.0.1 --debug
```

Expected:
1. `mcp-remote` performs Dynamic Client Registration against `https://mcp-auth.granola.ai/oauth2/register`.
2. Generates PKCE S256, requests scopes `openid profile email offline_access`. The `offline_access` scope is what produces a refresh token — without it, the integration breaks every hour.
3. Opens an authorization URL in a browser (or prints "Please visit: <url>" if auto-open fails).
4. The user authorizes in their browser; Granola redirects to `http://localhost:3334/oauth/callback`.
5. `mcp-remote` exchanges the code at `https://mcp-auth.granola.ai/oauth2/token` and writes:
   - `~/.mcp-auth/mcp-remote-*/<server-hash>_client_info.json`
   - `~/.mcp-auth/mcp-remote-*/<server-hash>_tokens.json`
   - `~/.mcp-auth/mcp-remote-*/<server-hash>_code_verifier.json`
6. Starts an MCP session — let it run ~5 seconds, then `Ctrl+C`.

Verify:

```bash
jq '{has_refresh: (.refresh_token|length>0), expires_at, scope}' \
  ~/.mcp-auth/mcp-remote-*/*_tokens.json
```

`has_refresh` must be `true`. If `false`, the `offline_access` scope was rejected — re-bootstrap.

### WSL2 fallback

If the browser doesn't open or the callback never reaches `mcp-remote`:

1. Add to `~/.wslconfig` on the Windows side:
   ```
   [wsl2]
   localhostForwarding=true
   ```
   Then `wsl --shutdown` from a Windows shell, reopen WSL, retry.

2. If that's already set, run the bootstrap on a different machine that has a native browser, then `rsync ~/.mcp-auth/mcp-remote-*/ user@wsl:~/.mcp-auth/mcp-remote-*/`.

## Phase 3: Discover MCP tool names

The official server's tool names are not documented; discover them once and lock the wrapper script's mapping:

```bash
HOME=$HOME printf '%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
| npx -y mcp-remote@0.1.38 https://mcp.granola.ai/mcp --host 127.0.0.1 2>/dev/null \
| grep '"id":2' | jq '.result.tools[] | {name, description, inputSchema}'
```

Record the resulting names + argument schemas — they drive Phase 4 step 2.

## Phase 4: Wire the agent group

Per target group folder under `groups/`:

### 4.1 container.json

**Do not** add a `granola` entry under `mcpServers`. Add only the mount:

```json
{
  "additionalMounts": [
    {
      "hostPath": "/home/<user>/.mcp-auth",
      "containerPath": "mcp-auth",
      "readonly": false
    }
  ]
}
```

### 4.2 Wrapper script

Install `groups/<folder>/scripts/granola.sh`. Skeleton (replace `<TOOL_NAME>` from Phase 3):

```bash
#!/bin/bash
set -euo pipefail

GRANOLA_BIN=(npx -y mcp-remote@0.1.38 https://mcp.granola.ai/mcp --host 127.0.0.1 --silent)
export MCP_REMOTE_CONFIG_DIR="/workspace/extra/mcp-auth"
export NO_PROXY="mcp.granola.ai,mcp-auth.granola.ai,api.granola.ai,localhost,127.0.0.1"

_call() {
  local tool="$1"
  local args_json="$2"
  printf '%s\n%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"granola-scripts","version":"1.0"}}}' \
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"${tool}\",\"arguments\":${args_json}}}" \
    | "${GRANOLA_BIN[@]}" 2>/dev/null \
    | grep '"id":2' \
    | node -e "
        const chunks = [];
        process.stdin.on('data', d => chunks.push(d));
        process.stdin.on('end', () => {
          const line = Buffer.concat(chunks).toString().trim();
          const d = JSON.parse(line);
          if (d.error) { console.error('Error:', d.error.message); process.exit(1); }
          console.log(d.result.content[0].text);
        });
      "
}

CMD="${1:-help}"
shift || true

case "$CMD" in
  list)         LIMIT="${1:-20}"; _call "<TOOL:list_meetings>" "{\"limit\":${LIMIT}}" ;;
  search)       Q="${1:?missing query}"; _call "<TOOL:query_granola_meetings>" "{\"query\":$(node -e "process.stdout.write(JSON.stringify(process.argv[1]))" "$Q")}" ;;
  # ...remaining commands (see in-container `granola` skill for full surface)...
  help|*)       echo "Usage: granola.sh <command> [args]"; ;;
esac
```

The CLI surface (`list/search/get/transcript/folders/...`) must match exactly what the in-container `granola` skill documents — don't drift, the skill is the agent's contract.

### 4.3 In-container skill

Already shipped at `container/skills/granola/SKILL.md` — no per-group install needed. The skill auto-disables on groups where `granola.sh` doesn't exist.

## Phase 5: OneCLI

Skip. OneCLI has no Granola provider entry and `mcp-remote` owns the OAuth lifecycle. The `NO_PROXY` in `granola.sh` keeps Granola hosts off the OneCLI gateway, which has nothing to inject for them anyway.

## Phase 6: Verification

1. Restart the target agent's container (kill + spawn).
2. From the host: `bash /home/<user>/projects/nanoclaw-v2/groups/<folder>/scripts/granola.sh list 3` — should not work (host doesn't have the mount). That's expected.
3. From inside the container: `bash /workspace/agent/scripts/granola.sh list 3` — should return JSON with 3 meetings.
4. Force-refresh test: clobber the access_token but keep the refresh_token, then call again:
   ```
   jq '.access_token="invalid",.expires_at=0' ~/.mcp-auth/mcp-remote-*/*_tokens.json | sponge $_
   bash /workspace/agent/scripts/granola.sh list 3
   ```
   `mcp-remote` should refresh transparently and the call should succeed.
5. Open Granola desktop on Windows/Mac (same account) — confirm it's unaffected.
6. Ask the agent (in chat): "list the last 3 Granola meetings". The agent should run `granola.sh list 3` per the in-container skill — not call any `mcp__granola*` tool. If it tries the latter, the skill is being ignored; check `container.json.skills` selection.

## Removal

Reverse phases 4 → 1:
- Delete `groups/<folder>/scripts/granola.sh`
- Remove the `mcp-auth` `additionalMounts` entry
- Remove `granola` from any per-group `skills` array (if not `"all"`)
- `rm -rf ~/.mcp-auth/mcp-remote-*/<granola-server-hash>_*`
- Optionally remove `/home/<user>/.mcp-auth` from `mount-allowlist.json` if no other remote MCP uses it

## Idempotency

- Mount allowlist edit is path-deduped on application
- `additionalMounts` edit checks for existing entry by `hostPath` before appending
- OAuth bootstrap with valid existing tokens just confirms session and exits — re-running is safe
- Script and skill files are overwritten; user-edited copies are not preserved (warn before overwrite if mtime indicates user edits)
- Re-running this skill will not duplicate any state
