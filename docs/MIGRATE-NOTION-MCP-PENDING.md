# Pending: migrate Notion MCP to script-mediated + OneCLI pattern

**Drafted**: 2026-04-29 18:09 CST (2026-04-30T00:09Z)
**Status**: TODO — postponed to a follow-up session
**Author**: Claude Opus 4.7 (1M context) at sigfreud's request after the Granola migration was completed the same day.

## Why this exists

The Granola integration was migrated today from `granola-mcp-plus` (broken every 6h) to the official OAuth MCP server bridged via `mcp-remote`, with:
1. The MCP **not declared** in `container.json.mcpServers` — invisible to the agent's tool list
2. A curated wrapper script (`granola.sh`) as the only entry point
3. An in-container skill (`container/skills/granola/SKILL.md`) routing the agent to the script
4. An operator-facing idempotent install skill (`/add-granola`)

Notion stayed on the legacy pattern: MCP declared in `mcpServers`, raw `NOTION_API_KEY` hardcoded in `env`, no script wrapper, no skill, no OneCLI. This is a security and consistency debt that should be paid in a dedicated session — not bundled into the Granola work.

## Current state of Notion (verified 2026-04-29)

- `groups/dm-with-sigfreud/container.json`:
  ```json
  "notion": {
    "command": "node",
    "args": ["/workspace/agent/notion-mcp/server.mjs"],
    "env": { "NOTION_API_KEY": "ntn_D79388168816uhxxzGSG6eVGBZbVtCc2nzxpWQ55wd85TH" }
  }
  ```
- Custom local MCP proxy at `groups/dm-with-sigfreud/notion-mcp/`:
  - `server.mjs` — local code (purpose unverified; likely safety/rate-limit wrapper, named `notion-mcp-proxy-safe` in package.json)
  - `package.json` — single dep `@modelcontextprotocol/sdk@^1.0.0`
  - `pnpm-lock.yaml` + `node_modules/`
- The MCP is **directly exposed** to Noctua's tool list. Agent calls `mcp__notion__<tool>` directly — no script mediation.
- The integration token is **static** (not OAuth, not refreshable).
- Notion auth uses `Authorization: Bearer <integration-token>` against `api.notion.com`.

## Target architecture (parallel to Granola)

Migrate to a 4-piece setup mirroring `/add-granola`:

1. **Remove `notion` from `mcpServers`** in `container.json`. The agent stops seeing notion tools directly.
2. **Move `NOTION_API_KEY` into OneCLI** with a host pattern matching `api.notion.com`. Stub the env value as `onecli-managed`. The OneCLI gateway intercepts outbound requests and swaps the bearer header at flight time. Pattern is identical to `/add-gmail-tool`'s "stub credentials + TLS-intercepting proxy" approach (see `.claude/skills/add-gmail-tool/SKILL.md`).
3. **Curated wrapper script** `groups/dm-with-sigfreud/scripts/notion.sh` exposing a stable CLI:
   - `pages-search <query>`
   - `page-get <page_id>`
   - `page-create <parent_id> <title> [body]`
   - `db-query <database_id> [filter]`
   - `db-pages <database_id>`
   - `block-append <page_id> <block_json>`
   - …finalize once `/add-notion` step-3 (tool discovery) runs against the actual server
4. **In-container skill** `container/skills/notion/SKILL.md` instructing Noctua: "for Notion tasks, run `bash /workspace/agent/scripts/notion.sh ...` — do NOT call any `mcp__notion*` tool directly."
5. **Operator install skill** `.claude/skills/add-notion/SKILL.md` — idempotent installer parallel to `/add-granola`.

## Decision pending: keep the custom proxy or drop it?

The current `notion-mcp-proxy-safe` may be doing useful filtering (e.g. blocking destructive operations, redacting sensitive fields, rate-limiting). Before the migration:
- Read `groups/dm-with-sigfreud/notion-mcp/server.mjs` to identify what it does
- If it's a thin passthrough → drop it, use the official Notion MCP server (`@notionhq/notion-mcp-server` if it exists, or `npx -y @makenotion/notion-mcp-server`) directly
- If it has real safety logic → keep it, just refactor auth to read `Authorization: Bearer onecli-managed` (the gateway swaps it)

Default assumption pending verification: **drop the custom proxy and use the official Notion MCP server**. Simpler, fewer files to maintain, OneCLI can swap the bearer regardless of which server speaks to `api.notion.com`. If `server.mjs` turns out to do non-trivial work, revisit.

## Outline of `/add-notion` SKILL.md

Mirror `.claude/skills/add-granola/SKILL.md` exactly. Phase structure:

```
Phase 1: Pre-flight
  1.1 Confirm OneCLI has Notion configured:
        onecli secrets list | grep -i notion
      Expected: a secret with hostPattern matching api.notion.com, value
      starting with "ntn_" (Notion's integration-token prefix).
      If missing: have user add it via OneCLI web UI at 127.0.0.1:10254
      (Apps → Notion → paste integration token).
  1.2 Mount allowlist: nothing new needed (no token cache like mcp-remote).

Phase 2: Tool-name discovery
  Run a one-shot probe against the chosen Notion MCP server with
  Authorization: Bearer onecli-managed (so OneCLI swaps in the real
  token) to dump tools/list. Capture exact names + inputSchemas to
  drive the wrapper script.

Phase 3: Wire the agent group
  3.1 container.json:
        - REMOVE the notion entry from mcpServers
        - env.NOTION_API_KEY = "onecli-managed"  (only if keeping the
          custom proxy and wiring it through OneCLI)
        - additionalMounts: no change for notion specifically
  3.2 If using official server: drop groups/<folder>/notion-mcp/ entirely
      (custom proxy no longer needed).
  3.3 Install scripts/notion.sh from a template in
      .claude/skills/add-notion/notion.sh.template.
  3.4 In-container skill: container/skills/notion/SKILL.md is shipped
      from this repo — no per-group install needed (auto-disables on
      groups without notion.sh, same convention as the granola skill).

Phase 4: OneCLI configuration
  4.1 Verify `onecli agents secrets --id <agent-id>` includes the notion
      secret (set-secret-mode all OR explicit assignment).
  4.2 Test the bearer-swap path: from the container,
        curl -H 'Authorization: Bearer onecli-managed' \
             https://api.notion.com/v1/users/me
      should succeed (OneCLI logs show the swap).

Phase 5: Verification
  - Container spawns with no granola/notion in mcpServers
  - bash /workspace/agent/scripts/notion.sh pages-search "anything"
    returns real Notion data
  - Agent in chat: "search my Notion for X" → uses notion.sh, not
    mcp__notion__* directly
  - Killing the OneCLI service makes notion.sh return a clear auth
    error (proves OneCLI is the credential path)

Removal: delete script + skill, restore mcpServers.notion if user
wants the legacy direct-MCP path back, remove OneCLI secret, etc.

Idempotency: same checks as /add-granola. Re-runs deduplicate state.

Update path: when @notionhq/notion-mcp-server bumps, edit the pinned
version in this SKILL.md, in scripts/notion.sh, and in the template.
Re-run `/add-notion` against existing groups.
```

## Steps for the future session (TL;DR)

1. **Read** `groups/dm-with-sigfreud/notion-mcp/server.mjs` and decide: keep custom proxy (refactor auth) or drop it (use official server). Default: drop.
2. **Discover** tool names from the chosen Notion MCP server (`tools/list` probe).
3. **Create** `groups/dm-with-sigfreud/scripts/notion.sh` (the wrapper).
4. **Create** `container/skills/notion/SKILL.md` (in-container guide for the agent).
5. **Create** `.claude/skills/add-notion/SKILL.md` (operator installer, idempotent).
6. **Edit** `groups/dm-with-sigfreud/container.json`:
   - Remove the `notion` entry from `mcpServers`
   - If keeping custom proxy: stub the env (`NOTION_API_KEY: "onecli-managed"`)
7. **Configure OneCLI**: add the Notion secret with host pattern `api.notion.com` (or `*.notion.com`), assign it to the Noctua agent (`agents set-secrets` or `set-secret-mode all`).
8. **Restart** Noctua's container; smoke-test the script.
9. **Commit** the source changes (`container/skills/notion/`, `.claude/skills/add-notion/`). Group changes (`scripts/notion.sh`, `container.json`, custom proxy removal) are gitignored — they live locally only.

## Reference patterns to copy from

- `.claude/skills/add-granola/SKILL.md` — the operator skill template (this is the closest analogue; mirror its structure)
- `.claude/skills/add-gmail-tool/SKILL.md` — the OneCLI stub-credentials pattern (since Gmail's static OAuth tokens are conceptually similar to Notion's static integration token: not refreshable, just swap headers in flight)
- `groups/dm-with-sigfreud/scripts/granola.sh` — the wrapper script structure (preserve the JSON-RPC plumbing pattern, only change the spawn target and tool names)
- `container/skills/granola/SKILL.md` — the in-container skill format

## Risks specific to Notion

- **Rate limits**: Notion's API is more rate-limited than Granola's. The wrapper should consider adding client-side backoff if the official server doesn't already.
- **Scope of integration token**: integration tokens are scoped to the pages/databases explicitly shared with the integration in Notion's UI. The migration won't widen access; if the agent is currently failing on a page, it's because that page isn't shared, not because of the token.
- **No refresh path**: unlike Granola, there's no refresh_token. If the integration token gets revoked (Sigfreud manually rotates in Notion settings), the user must regenerate it and update the OneCLI secret. Failure mode is loud (401) and recovery is one OneCLI edit.
- **Custom proxy drop risk**: if `server.mjs` does something non-obvious (e.g. blocks `archive_page`), dropping it in favor of the official server could expose Noctua to destructive operations. Read the code carefully before dropping.

## How to find this doc in a future session

The doc filename is `docs/MIGRATE-NOTION-MCP-PENDING.md`. A project-level memory note should also point here — when a new Claude session starts, it'll see the pointer in `MEMORY.md`. If that's not set up, just `ls docs/MIGRATE-*` from the repo root.
