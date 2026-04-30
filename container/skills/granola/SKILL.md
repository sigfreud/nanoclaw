---
name: granola
description: Access Granola meeting notes, transcripts, calendar events, folders, and shared documents via the curated wrapper script. Triggers on user requests mentioning Granola, meetings, transcripts, notes, conversations, folders, or workspaces when the group has Granola configured.
---

# Granola

If the group has Granola configured, the wrapper script `/workspace/agent/scripts/granola.sh` is the **only** supported entry point. It owns OAuth token management, automatic refresh, retries, and output filtering. Calling any `mcp__granola*` tool directly (or any other Granola MCP tool that may surface) is **not allowed** — the integration is intentionally script-mediated.

Quick check the group has it: `test -x /workspace/agent/scripts/granola.sh && echo yes`. If it returns `yes`, this skill applies. If not, Granola isn't configured for this group — surface that to the user instead of attempting calls.

## CLI surface

```
bash /workspace/agent/scripts/granola.sh <command> [args]
```

| Command | Purpose |
|---|---|
| `list [time_range] [N]` | meetings in a range (default `last_30_days`; enum: `this_week`, `last_week`, `last_30_days`, `custom`). N is a client-side hint, not always honored. |
| `search <query>` | natural-language query over meetings (returns numbered citation links) |
| `search-transcripts <query>` | alias for `search` (server is unified) |
| `get <meeting_id>` | one meeting (notes, AI summary, attendees) |
| `transcript <meeting_id>` | verbatim transcript |
| `raw-transcript <meeting_id>` | alias for `transcript` (server doesn't expose per-utterance timestamps) |
| `folders` | list folders |
| `folder-docs <folder_id> [N]` | meetings in a folder |
| `shared-doc <meeting_id>` | alias for `get` |

**Output formats** (vary by tool — don't assume JSON):
- `list` and `folder-docs` return XML-tagged text (`<meetings_data>...<meeting id="..." title="..." date="..."/>...`). Extract IDs with regex `/<meeting\s+id="([^"]+)"/g`.
- `search`/`search-transcripts` return Markdown text with inline citations like `[[0]](url)`. **Preserve those citations** in your response to the user — they're the audit trail.
- `folders` returns JSON: `{count, folders: [{id, title, description, note_count}]}`.
- `get` returns markdown with notes, summary, attendees.
- `transcript` returns plain text (verbatim).

Don't dump raw output to the user — extract the relevant fields.

## Error handling

If `granola.sh` exits non-zero or output mentions auth failure / 401 / `OAuth metadata fetch failed`, the OAuth refresh chain is broken and a human needs to re-bootstrap (see the operator skill `/add-granola`, "OAuth bootstrap" step). **Do not attempt to recover yourself** — surface the error verbatim to the user and stop.

If `granola.sh` succeeds but returns an empty or unexpected payload, the official MCP server may have changed shape. Surface the raw output and ask the user.

## Why script-mediated

Calling MCP tools directly loads verbose tool schemas into context on every turn and dumps raw structured payloads back. The wrapper trades a small spawn cost for: stable CLI surface across MCP-server changes, consistent error semantics, encapsulated OAuth lifecycle, and filtered outputs that don't blow up context.
