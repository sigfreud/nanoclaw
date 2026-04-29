# Anthropic Token Rotation

This NanoClaw install uses a **Claude Max subscription OAuth token** generated via `claude setup-token` and stored in the OneCLI vault. Subscription OAuth tokens are long-lived but not indefinite; they need manual rotation once a year.

## Current token

| Field | Value |
|---|---|
| Issue date | 2026-04-23 |
| Hard expiry | 2027-04-23 (1 year from issue, per Anthropic docs) |
| **Rotate by** | **2027-03-24** (30-day buffer before hard expiry) |
| OneCLI secret id | `7e45b98e-b34b-413f-ac7a-949bc17369ab` |
| OneCLI secret name | `Anthropic` |
| Type / host pattern | `anthropic` / `api.anthropic.com` |
| Token format | `sk-ant-oat…AA` (one-year OAuth, scope: inference only) |

Token value is **never** stored here — only in the OneCLI vault.

## Why this rotation exists

Per Anthropic docs (`code.claude.com/docs/en/authentication#generate-a-long-lived-token`):

> "For CI pipelines, scripts, or other environments where interactive browser login isn't available, generate a **one-year OAuth token** with `claude setup-token`."

One year sounds long, but if we forget, the NanoClaw service stops responding at 2027-04-23 with opaque 401s. That is the exact failure mode this rotation procedure exists to prevent.

## Rotation procedure

Run this annually. Takes ~2 minutes.

### Step 1 — new token from Anthropic, stored into the vault

In a real terminal (not via Claude Code's `!` — needs a controlling TTY for the browser OAuth flow):

```bash
cd ~/projects/nanoclaw-v2   # or wherever this checkout lives
PATH="$HOME/.local/bin:$PATH" bash setup/register-claude-token.sh
```

The script:
1. Invokes `claude setup-token` under `script(1)` for PTY capture.
2. Opens your browser for Claude Max sign-in.
3. Extracts the `sk-ant-oat…AA` token from the captured output.
4. Calls `onecli secrets create --name Anthropic --type anthropic --host-pattern api.anthropic.com --value <token>` to store it.

A new `Anthropic` secret appears in the vault, alongside the old one.

### Step 2 — delete the old secret

```bash
onecli secrets list
# find the older entry's id (smaller createdAt)
onecli secrets delete --id <old-id>
```

### Step 3 — verify the cutover

```bash
# Send a test message through whichever channel is registered.
# If the agent replies, you're done.
# If you get a 401, the NEW secret didn't land — run list again, check which id is active.
```

### Step 4 — bump this file

Edit the "Current token" table above with the new issue date, new hard expiry (issue + 365 days), new rotate-by (issue + 335 days), and the new secret id. Commit the change.

## Reminders

Two automated pings keep this from being a surprise:

1. **Monthly upstream-lag check** — first Sunday of each month. A scheduled Claude Code agent runs `git fetch upstream main && git log --oneline main..upstream/main | wc -l`; if non-zero, pings the registered channel with the count and top 5 commit titles. Keeps this install from drifting hundreds of commits behind upstream again.
2. **Token rotation reminder** — fires once on **2027-03-24**. Sends a one-line message: "NanoClaw Anthropic token needs rotation; see `docs/TOKEN-ROTATION.md` on `upgrade/onecli-canonical` (or wherever `main` is by then)."

Both are set up via `/schedule` on this Claude Code install.

## Fallback — manual full reset

If the rotation procedure misbehaves (e.g., `claude setup-token` fails, OneCLI refuses the secret, browser OAuth dies), the full from-scratch reset:

```bash
# 1. Log out of the Claude CLI subscription (invalidates all subscription OAuth tokens, including setup-token results)
claude /logout

# 2. Log in fresh
claude           # opens the browser for sign-in, establishes interactive OAuth

# 3. Generate a new setup-token under the fresh session
claude setup-token

# 4. Store it in OneCLI manually (one line, no wrapping!)
PATH=$HOME/.local/bin:$PATH onecli secrets create --name Anthropic --type anthropic --host-pattern api.anthropic.com --value 'PASTE_TOKEN_HERE'

# 5. Remove the old secret via `onecli secrets delete --id <old-id>`
```

## Security notes

- The token is stored encrypted at rest in OneCLI's postgres volume (`onecli_pgdata`).
- The OneCLI gateway runs on `127.0.0.1:10254`/`:10255` only; not exposed to the network.
- OneCLI injects the token into outbound requests to `api.anthropic.com` from agent containers. The containers never see the value directly.
- A leaked token should be rotated as above. Anthropic does not currently expose a UI to revoke a specific `setup-token`; running `claude /logout` followed by a fresh login is the closest to a manual revoke.
