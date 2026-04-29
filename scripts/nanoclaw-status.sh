#!/usr/bin/env bash
#
# nanoclaw-status — quick health check for a NanoClaw install.
#
# Resolves the project root from its own location (follows symlinks), so it
# can be invoked directly or via a $PATH symlink. Designed for fast remote
# triage: probes host, containers, OneCLI, network, DB and logs in <2s and
# prints a single OVERALL verdict with a short, actionable issue summary.
#
# Usage:
#   ./scripts/nanoclaw-status.sh           # full report
#   ./scripts/nanoclaw-status.sh -v        # verbose: log tails + container detail
#   ./scripts/nanoclaw-status.sh -q        # one-line OVERALL (cron/scripting)
#   ./scripts/nanoclaw-status.sh -h        # help
#
# Exit codes:
#   0  HEALTHY    — all sections green
#   1  DEGRADED   — host running but at least one issue
#   2  DOWN       — host process not running
#   3  invocation error (bad flag / unresolved project root)
#
# Env overrides:
#   NANOCLAW_INSTALL_SLUG   override the auto-computed Docker label slug
#   NO_COLOR                disable ANSI colors (also auto-off on non-TTY)
#
# Tip — global access from any cwd:
#   ln -s "$(pwd)/scripts/nanoclaw-status.sh" ~/.local/bin/nanoclaw-status

set -euo pipefail

# ─── path resolution ────────────────────────────────────────────────────

resolve_self() {
  local src="${BASH_SOURCE[0]}"
  while [ -L "$src" ]; do
    local dir
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    [[ "$src" != /* ]] && src="$dir/$src"
  done
  cd -P "$(dirname "$src")" && pwd
}

SCRIPT_DIR="$(resolve_self)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

if [ ! -f "$PROJECT_ROOT/package.json" ] \
   || ! grep -q '"name":[[:space:]]*"nanoclaw"' "$PROJECT_ROOT/package.json" 2>/dev/null; then
  printf 'nanoclaw-status: cannot locate NanoClaw project root from %s\n' "$SCRIPT_DIR" >&2
  exit 3
fi

# ─── flag parsing ───────────────────────────────────────────────────────

VERBOSE=false
QUIET=false
FORCE_NO_COLOR=false
LOGS_N=10

usage() {
  cat <<EOF
nanoclaw-status — quick health check for a NanoClaw install

USAGE
  nanoclaw-status [flags]

DESCRIPTION
  Probes host process, session containers, OneCLI gateway and proxy,
  public network endpoints, central DB and logs in under 2 seconds.
  Prints a single OVERALL verdict (HEALTHY / DEGRADED / DOWN) and, when
  something is wrong, a short actionable summary with a hint to open
  Claude Code from the project root for deeper diagnosis.

OPTIONS
  -v, --verbose       Include log tails and per-container detail
  -q, --quiet         Print only the OVERALL line (cron / scripting)
      --no-color      Disable ANSI colors (auto-off on non-TTY)
      --logs N        Lines of recent errors in --verbose (default: 10)
  -h, --help          Show this message and exit

EXIT CODES
  0   HEALTHY    all sections green
  1   DEGRADED   host running but at least one issue
  2   DOWN       host process not running
  3   ERROR      invocation error (bad flag / unresolved project root)

ENVIRONMENT
  NANOCLAW_INSTALL_SLUG    Override the auto-computed Docker label slug.
                           Default: sha1(<project-root>) truncated to 8 chars.
  NO_COLOR                 Disable ANSI colors (also auto-off on non-TTY).

EXAMPLES
  nanoclaw-status                # full report (interactive use)
  nanoclaw-status -q             # one-line OVERALL (monitors / prompts)
  nanoclaw-status -v --logs 20   # debug: container detail + last 20 errs
  nanoclaw-status -q || alert    # chain into alerting in shell scripts

INSTALLATION
  Symlink the script into your \$PATH so it runs from any cwd:

      ln -s "$PROJECT_ROOT/scripts/nanoclaw-status.sh" \\
            ~/.local/bin/nanoclaw-status

  Anatomy of that command:

      ln  -s     <target>           <link-name>
      │   │         │                    │
      │   │         │                    └─ where the shortcut lives.
      │   │         │                       ~/.local/bin is the XDG
      │   │         │                       convention, usually in PATH.
      │   │         └─ the real script. The script uses readlink -f
      │   │            internally, so it always finds its project root
      │   │            no matter how you invoke it.
      │   └─ "symbolic" — deletable, non-destructive
      └─ "link" — Unix command that creates file links

  Verify after install:
      ls -l ~/.local/bin/nanoclaw-status                 # arrow → target
      echo "\$PATH" | tr ':' '\\n' | grep -F .local/bin   # confirm in PATH

  If ~/.local/bin is not in PATH, add it to ~/.bashrc:
      echo 'export PATH="\$HOME/.local/bin:\$PATH"' >> ~/.bashrc
      source ~/.bashrc

  Repoint (e.g. after moving the project) or remove:
      ln -sf <new-path> ~/.local/bin/nanoclaw-status     # force-repoint
      rm ~/.local/bin/nanoclaw-status                    # remove (script untouched)

PROJECT
  $PROJECT_ROOT
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -v|--verbose)  VERBOSE=true ;;
    -q|--quiet)    QUIET=true ;;
    --no-color)    FORCE_NO_COLOR=true ;;
    --logs)        shift; LOGS_N="${1:-10}" ;;
    -h|--help)     usage; exit 0 ;;
    *) printf 'nanoclaw-status: unknown flag: %s\n\n' "$1" >&2; usage >&2; exit 3 ;;
  esac
  shift
done

# ─── color helpers (mirrors nanoclaw.sh:101-117) ────────────────────────

use_ansi() {
  $FORCE_NO_COLOR && return 1
  [ -t 1 ] && [ -z "${NO_COLOR:-}" ]
}
dim()    { use_ansi && printf '\033[2m%s\033[0m'  "$1" || printf '%s' "$1"; }
gray()   { use_ansi && printf '\033[90m%s\033[0m' "$1" || printf '%s' "$1"; }
red()    { use_ansi && printf '\033[31m%s\033[0m' "$1" || printf '%s' "$1"; }
green()  { use_ansi && printf '\033[32m%s\033[0m' "$1" || printf '%s' "$1"; }
yellow() { use_ansi && printf '\033[33m%s\033[0m' "$1" || printf '%s' "$1"; }
bold()   { use_ansi && printf '\033[1m%s\033[0m'  "$1" || printf '%s' "$1"; }

dot_ok()   { green  '●'; }
dot_warn() { yellow '●'; }
dot_bad()  { red    '●'; }

# ─── layout helpers ─────────────────────────────────────────────────────

WIDTH=72
HBAR=$(printf '═%.0s' $(seq 1 $WIDTH))

hbar() { $QUIET || printf '%s\n' "$HBAR"; }

section() {
  $QUIET && return 0
  local title=$1
  local prefix="─── $title "
  local pad=$(( WIDTH - ${#prefix} ))
  [ $pad -lt 0 ] && pad=0
  local fill
  fill=$(printf '─%.0s' $(seq 1 $pad))
  printf '\n%s\n' "$(gray "${prefix}${fill}")"
}

note() { $QUIET || printf '  %s\n' "$1"; }

# ─── state accumulators ─────────────────────────────────────────────────
# ISSUES entries are sev<US>msg<US>hint, where <US> = ASCII 0x1f. Using a
# control char instead of '|' so error text containing pipes can't corrupt
# the parse on the way back out.

ISSUES=()
push_issue() { ISSUES+=("$1"$'\x1f'"$2"$'\x1f'"$3"); }

HOST_RUNNING=false
HOST_PID=""
HOST_ETIME=""
HOST_RSS=""
SERVICE_MGR=""

CONTAINERS_AVAILABLE=false
CONTAINERS_LIST=""
CONTAINERS_COUNT=0

ONECLI_GATEWAY="ERR|0"
ONECLI_PROXY="ERR|0"

NET_ANTHROPIC="ERR|0"
NET_TELEGRAM="ERR|0"
NET_GITHUB="ERR|0"

DB_EXISTS=false
DB_AGE=""
DB_AGENTS=""
DB_GROUPS=""
DB_SESSIONS=""

MAIN_LOG="$PROJECT_ROOT/logs/nanoclaw.log"
ERR_LOG="$PROJECT_ROOT/logs/nanoclaw.error.log"
MAIN_LOG_AGE=""
ERR_LOG_AGE=""
ERR_LOG_AGE_S=999999
ERR_LOG_LINES=0

# ─── install slug (replicates src/install-slug.ts: sha1(root)[:8]) ──────

if [ -n "${NANOCLAW_INSTALL_SLUG:-}" ]; then
  INSTALL_SLUG="$NANOCLAW_INSTALL_SLUG"
elif command -v sha1sum >/dev/null 2>&1; then
  INSTALL_SLUG=$(printf '%s' "$PROJECT_ROOT" | sha1sum | cut -c1-8)
else
  INSTALL_SLUG="unknown"
fi

# ─── small utilities ────────────────────────────────────────────────────

stat_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

file_age_seconds() { echo $(( $(date +%s) - $(stat_mtime "$1") )); }

file_age() {
  local age_s; age_s=$(file_age_seconds "$1")
  if   [ "$age_s" -lt 60 ];    then echo "${age_s}s ago"
  elif [ "$age_s" -lt 3600 ];  then echo "$((age_s/60))m ago"
  elif [ "$age_s" -lt 86400 ]; then echo "$((age_s/3600))h ago"
  else                              echo "$((age_s/86400))d ago"
  fi
}

pretty_etime() {
  local e=$1 d=0 h=0 m=0
  if [[ "$e" == *-* ]]; then d="${e%%-*}"; e="${e#*-}"; fi
  IFS=: read -ra parts <<<"$e"
  if   [ "${#parts[@]}" -eq 3 ]; then h=$((10#${parts[0]})); m=$((10#${parts[1]}))
  elif [ "${#parts[@]}" -eq 2 ]; then m=$((10#${parts[0]}))
  fi
  local out=""
  [ "$d" -gt 0 ] && out+="${d}d "
  [ "$h" -gt 0 ] && out+="${h}h "
  out+="${m}m"
  echo "$out"
}

pretty_rss() {
  local kb=${1:-0}
  if   [ "$kb" -ge 1048576 ]; then awk -v k="$kb" 'BEGIN{printf "%.1f GB", k/1048576}'
  elif [ "$kb" -ge 1024 ];    then awk -v k="$kb" 'BEGIN{printf "%d MB", k/1024}'
  else                              echo "${kb} KB"
  fi
}

http_probe() {  # url, timeout_s -> "code|seconds"
  local url=$1 t=${2:-2}
  command -v curl >/dev/null 2>&1 || { echo "ERR|0"; return; }
  curl -sS --max-time "$t" -o /dev/null -w '%{http_code}|%{time_total}' "$url" 2>/dev/null \
    || echo "ERR|0"
}

ms_from_seconds() { awk -v t="${1:-0}" 'BEGIN{printf "%.0f ms", t*1000}'; }

# ─── probes ─────────────────────────────────────────────────────────────

probe_host() {
  local match
  match=$(ps -eo pid=,etime=,rss=,cmd= 2>/dev/null \
    | awk -v root="$PROJECT_ROOT" '$0 ~ root && $0 ~ /index\.(ts|js)/ && $0 !~ /grep/ {print; exit}' \
    || true)
  if [ -n "$match" ]; then
    HOST_RUNNING=true
    HOST_PID=$(awk '{print $1}' <<<"$match")
    HOST_ETIME=$(awk '{print $2}' <<<"$match")
    HOST_RSS=$(awk '{print $3}' <<<"$match")
  fi
  if command -v systemctl >/dev/null 2>&1 \
     && systemctl --user is-active nanoclaw >/dev/null 2>&1; then
    SERVICE_MGR="systemd user (nanoclaw.service)"
  elif command -v launchctl >/dev/null 2>&1 \
       && launchctl list 2>/dev/null | grep -q com.nanoclaw; then
    SERVICE_MGR="launchd (com.nanoclaw)"
  fi
}

probe_containers() {
  command -v docker >/dev/null 2>&1 || return 0
  CONTAINERS_AVAILABLE=true
  CONTAINERS_LIST=$(docker ps \
    --filter "label=nanoclaw-install=$INSTALL_SLUG" \
    --format '{{.Names}}|{{.Status}}' 2>/dev/null || true)
  if [ -n "$CONTAINERS_LIST" ]; then
    CONTAINERS_COUNT=$(printf '%s\n' "$CONTAINERS_LIST" | wc -l | tr -d ' ')
  fi
}

probe_onecli() {
  ONECLI_GATEWAY=$(http_probe http://127.0.0.1:10254/ 2)
  ONECLI_PROXY=$(http_probe   http://127.0.0.1:10255/ 2)
}

probe_network() {
  local td; td=$(mktemp -d)
  ( http_probe https://api.anthropic.com/ 3 > "$td/a" ) &
  ( http_probe https://api.telegram.org/  3 > "$td/t" ) &
  ( http_probe https://github.com/        3 > "$td/g" ) &
  wait
  NET_ANTHROPIC=$(cat "$td/a")
  NET_TELEGRAM=$(cat "$td/t")
  NET_GITHUB=$(cat "$td/g")
  rm -rf "$td"
}

probe_db() {
  local db="$PROJECT_ROOT/data/v2.db"
  [ -f "$db" ] || return 0
  DB_EXISTS=true
  DB_AGE=$(file_age "$db")
  if command -v sqlite3 >/dev/null 2>&1; then
    DB_AGENTS=$(sqlite3   "$db" 'SELECT COUNT(*) FROM agent_groups'     2>/dev/null || echo '?')
    DB_GROUPS=$(sqlite3   "$db" 'SELECT COUNT(*) FROM messaging_groups' 2>/dev/null || echo '?')
    DB_SESSIONS=$(sqlite3 "$db" 'SELECT COUNT(*) FROM sessions'         2>/dev/null || echo '?')
  fi
}

probe_logs() {
  if [ -f "$MAIN_LOG" ]; then
    MAIN_LOG_AGE=$(file_age "$MAIN_LOG")
  fi
  if [ -f "$ERR_LOG" ]; then
    ERR_LOG_AGE=$(file_age "$ERR_LOG")
    ERR_LOG_AGE_S=$(file_age_seconds "$ERR_LOG")
    ERR_LOG_LINES=$(wc -l < "$ERR_LOG" 2>/dev/null | tr -d ' ')
  fi
}

# ─── render ─────────────────────────────────────────────────────────────

render_header() {
  $QUIET && return 0
  hbar
  printf '  %s %s\n' "$(bold 'NanoClaw Status')" "$(dim "— install $INSTALL_SLUG")"
  printf '  %s\n'    "$(dim "$PROJECT_ROOT")"
  printf '  %s\n'    "$(dim "$(date '+%Y-%m-%d %H:%M:%S %Z')")"
  hbar
}

render_host() {
  section "HOST"
  if $HOST_RUNNING; then
    note "$(dot_ok)  running   $(dim 'pid') $(bold "$HOST_PID")   $(dim 'up') $(bold "$(pretty_etime "$HOST_ETIME")")   $(dim 'rss') $(bold "$(pretty_rss "$HOST_RSS")")"
    note "$(dim "source: ${SERVICE_MGR:-standalone process (no service manager)}")"
  else
    note "$(dot_bad)  not running"
    push_issue "✗" "host process not running" "cd $PROJECT_ROOT && pnpm run dev   # or restart your service unit"
  fi
}

render_containers() {
  section "CONTAINERS"
  if ! $CONTAINERS_AVAILABLE; then
    note "$(dot_warn)  docker CLI not available — skipping"
    return 0
  fi
  if [ "$CONTAINERS_COUNT" -eq 0 ]; then
    note "$(dim "no active session containers (idle)")"
    return 0
  fi
  note "$(dot_ok)  $(bold "$CONTAINERS_COUNT") active session container(s)  $(dim "(label nanoclaw-install=$INSTALL_SLUG)")"
  if $VERBOSE; then
    while IFS='|' read -r name status; do
      [ -z "$name" ] && continue
      note "  $(dim '·') $name   $(dim "$status")"
    done <<<"$CONTAINERS_LIST"
  fi
}

render_onecli() {
  section "ONECLI"
  local code time
  IFS='|' read -r code time <<<"$ONECLI_GATEWAY"
  if [ "$code" = "200" ]; then
    note "$(dot_ok)  gateway   127.0.0.1:10254   $(bold "$code")   $(dim "$(ms_from_seconds "$time")")"
  elif [ "$code" = "ERR" ]; then
    note "$(dot_bad)  gateway   127.0.0.1:10254   unreachable"
    push_issue "✗" "OneCLI gateway unreachable on 127.0.0.1:10254" "OneCLI service may be down — credentialed actions will hang"
  else
    note "$(dot_warn)  gateway   127.0.0.1:10254   $(bold "$code")   $(dim 'unexpected status')"
    push_issue "!" "OneCLI gateway returned HTTP $code (expected 200)" "check OneCLI process and logs"
  fi
  IFS='|' read -r code time <<<"$ONECLI_PROXY"
  if [ "$code" = "ERR" ]; then
    note "$(dot_bad)  proxy     127.0.0.1:10255   unreachable"
    push_issue "✗" "OneCLI proxy unreachable on 127.0.0.1:10255" "containers will fail outbound HTTPS calls"
  else
    note "$(dot_ok)  proxy     127.0.0.1:10255   $(bold "$code")   $(dim "reachable (CONNECT-only)")"
  fi
}

render_network() {
  section "NETWORK"
  local entry host result code time
  for entry in "api.anthropic.com|$NET_ANTHROPIC" \
               "api.telegram.org|$NET_TELEGRAM" \
               "github.com|$NET_GITHUB"; do
    IFS='|' read -r host result <<<"$entry"
    IFS='|' read -r code time   <<<"$result"
    if [ "$code" = "ERR" ] || [ -z "$code" ]; then
      note "$(dot_bad)  $(printf '%-20s' "$host")   unreachable"
      push_issue "✗" "$host unreachable" "check internet / proxy / DNS"
    else
      note "$(dot_ok)  $(printf '%-20s' "$host")   $(bold "$code")   $(dim "$(ms_from_seconds "$time")")"
    fi
  done
}

render_db() {
  section "DB"
  if ! $DB_EXISTS; then
    note "$(dot_bad)  data/v2.db missing"
    push_issue "✗" "data/v2.db not found" "host has not started yet, or data/ was wiped"
    return 0
  fi
  note "$(dot_ok)  data/v2.db   $(dim "modified $DB_AGE")"
  if [ -n "$DB_AGENTS" ]; then
    note "       agent_groups: $(bold "$DB_AGENTS")   messaging_groups: $(bold "$DB_GROUPS")   sessions: $(bold "$DB_SESSIONS")"
  else
    note "       $(dim '(install sqlite3 for table counts)')"
  fi
}

render_logs() {
  section "LOGS"
  if [ -n "$MAIN_LOG_AGE" ]; then
    # NOTE: log idleness alone is not a stuck-delivery signal — it just means
    # nobody messaged the agent recently. Detecting a truly stuck delivery
    # loop would require inspecting outbound.db for unsent rows; keep this
    # informational only.
    note "$(dim 'main log: ')  last activity $(bold "$MAIN_LOG_AGE")"
  else
    note "$(dot_warn)  main log not present yet ($MAIN_LOG)"
  fi
  if [ -n "$ERR_LOG_AGE" ]; then
    note "$(dim 'error log:')  last write    $(bold "$ERR_LOG_AGE")   $(dim "($ERR_LOG_LINES total lines)")"
    if $HOST_RUNNING && [ "$ERR_LOG_AGE_S" -lt 300 ]; then
      local sample
      # Strip ANSI escapes (the host's pino logger writes colorized text to disk)
      # before truncating, otherwise we cut mid-escape and dump garbage.
      sample=$(grep -aE '(error|ERROR|Error|fail|Fail)' "$ERR_LOG" 2>/dev/null \
        | tail -1 \
        | sed -E 's/\x1b\[[0-9;]*m//g' \
        | sed -E 's/^[[:space:]]+//' \
        | cut -c1-90)
      push_issue "!" "fresh errors logged $((ERR_LOG_AGE_S/60))m ago" "${sample:-(see logs/nanoclaw.error.log)}"
    fi
    if $VERBOSE && [ "$ERR_LOG_LINES" -gt 0 ]; then
      note "$(dim "── tail -n $LOGS_N ──")"
      while IFS= read -r line; do
        note "$(gray "│ $line")"
      done < <(tail -n "$LOGS_N" "$ERR_LOG")
    fi
  else
    note "$(dim 'error log:')  not yet created"
  fi
}

EXIT_CODE=0

render_overall() {
  local verdict dot painted
  if ! $HOST_RUNNING; then
    verdict="DOWN";     EXIT_CODE=2; dot=$(dot_bad);  painted=$(red    "$verdict")
  elif [ "${#ISSUES[@]}" -gt 0 ]; then
    verdict="DEGRADED"; EXIT_CODE=1; dot=$(dot_warn); painted=$(yellow "$verdict")
  else
    verdict="HEALTHY";  EXIT_CODE=0; dot=$(dot_ok);   painted=$(green  "$verdict")
  fi

  if $QUIET; then
    if [ "${#ISSUES[@]}" -gt 0 ]; then
      printf '%s %s · %d issue(s) · install %s\n' "$dot" "$painted" "${#ISSUES[@]}" "$INSTALL_SLUG"
    else
      printf '%s %s · install %s\n' "$dot" "$painted" "$INSTALL_SLUG"
    fi
    return 0
  fi

  echo
  hbar
  if [ "${#ISSUES[@]}" -gt 0 ]; then
    printf '  %s %s   %s   %s\n' "$dot" "$(bold OVERALL:)" "$painted" "$(dim "${#ISSUES[@]} issue(s)")"
  elif [ "$verdict" = "HEALTHY" ]; then
    printf '  %s %s   %s   %s\n' "$dot" "$(bold OVERALL:)" "$painted" "$(dim 'todo en orden')"
  else
    printf '  %s %s   %s\n'      "$dot" "$(bold OVERALL:)" "$painted"
  fi

  if [ "${#ISSUES[@]}" -gt 0 ]; then
    echo
    local sev msg hint
    for issue in "${ISSUES[@]}"; do
      IFS=$'\x1f' read -r sev msg hint <<<"$issue"
      if [ "$sev" = "✗" ]; then
        printf '  %s %s\n' "$(red    '✗')" "$msg"
      else
        printf '  %s %s\n' "$(yellow '!')" "$msg"
      fi
      printf '    %s %s\n' "$(dim '└')" "$(dim "$hint")"
    done
    echo
    printf '  %s\n'   "$(dim 'Para diagnóstico profundo o corrección, abre Claude Code:')"
    printf '    %s\n' "$(bold "cd $PROJECT_ROOT && claude")"
  fi
  hbar
}

# ─── main ───────────────────────────────────────────────────────────────

probe_host
probe_containers
probe_onecli
probe_network
probe_db
probe_logs

render_header
render_host
render_containers
render_onecli
render_network
render_db
render_logs
render_overall

exit "$EXIT_CODE"
