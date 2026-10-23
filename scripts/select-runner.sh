#!/usr/bin/env bash
# select-runner.sh: decide `runs-on` for CI jobs: prefer a self-hosted runner when one is
# available, otherwise fall back to a GitHub-hosted label. Never fails the pipeline because of
# the picker: every decision exits 0 and every error degrades to the fallback.
#
# Inputs (environment only; secrets are never taken from flags):
#   GH_TOKEN      fine-grained PAT with Administration: read (may be empty => fallback)
#   REPO          owner/repo (required)
#   EVENT_NAME    github.event_name (required)
#   HEAD_REPO     PR head repo full name (pull_request events; empty => treated as fork)
#   LABELS        comma list of required runner labels (default: mac-studio)
#   FALLBACK      runs-on when not self-hosted (default: ubuntu-latest)
#   PREFER_QUEUE  true => self-hosted even when every matching runner is busy (default: false)
#   TIMEOUT       per API call, seconds, "10" or "10s" (default: 10)
#   RETRIES       max attempts per API call (default: 3), exponential backoff with jitter
#   API_URL       default https://api.github.com (tests)
#   TRUSTED_EVENTS space list (default: push workflow_dispatch schedule merge_group pull_request)
#   MAX_WAIT      cap in seconds on a single Retry-After wait (default: 30)
#   GITHUB_OUTPUT / GITHUB_STEP_SUMMARY: written when set.
# Exit codes: 0 decision made (including every fallback); 64 invalid usage/env (fallback is
# still written to $GITHUB_OUTPUT so pipelines keep working).
set +x
set -u
VERSION="1.0.0"
PROG="select-runner"
JSON_ONLY=0

usage() {
  cat <<'USAGE'
Usage: select-runner.sh [--json] [--help] [--version]

Decides runs-on for downstream jobs: self-hosted when a matching runner is online and
idle (and the event is trusted), otherwise the fallback. See the header of this file or
docs/RUNNERS.md for the environment variables.

  --json     only print the one-line JSON summary on stdout (human line to stderr)
  --help     this text
  --version  print version

Exit codes: 0 decision made (always, including fallbacks); 64 invalid usage or env.
USAGE
}

for a in "$@"; do
  case "$a" in
    --help | -h) usage; exit 0 ;;
    --version) echo "$PROG $VERSION"; exit 0 ;;
    --json) JSON_ONLY=1 ;;
    *) echo "$PROG: unknown argument: $a" >&2; usage >&2; BAD_ARG=1 ;;
  esac
done

TOKEN="${GH_TOKEN:-}"
unset GH_TOKEN
REPO="${REPO:-}"
EVENT_NAME="${EVENT_NAME:-}"
HEAD_REPO="${HEAD_REPO:-}"
LABELS="${LABELS:-mac-studio}"
FALLBACK="${FALLBACK:-ubuntu-latest}"
PREFER_QUEUE="${PREFER_QUEUE:-false}"
TIMEOUT="${TIMEOUT:-10}"
RETRIES="${RETRIES:-3}"
API_URL="${API_URL:-https://api.github.com}"
TRUSTED_EVENTS="${TRUSTED_EVENTS:-push workflow_dispatch schedule merge_group pull_request}"
MAX_WAIT="${MAX_WAIT:-30}"
SLEEP="${SELECT_RUNNER_SLEEP:-sleep}"
TIMEOUT="${TIMEOUT%s}"

SELFHOSTED=false
REASON=""
RUNS_ON_SELF="[]"
ONLINE=0; IDLE=0; BUSY=0
LAST_ERR=""

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# JSON-encode FALLBACK: a JSON array passes through, anything else becomes a JSON string.
fallback_json() {
  local f="$FALLBACK" out
  case "$f" in
    "["*) if out=$(printf '%s' "$f" | jq -ce 'select(type=="array")' 2>/dev/null) && [ -n "$out" ]; then printf '%s' "$out"; return; fi ;;
  esac
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$f" | jq -Rsc '.'
  else
    printf '"%s"' "$(printf '%s' "$f" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  fi
}

finish() { # finish <exit-code>
  local rc="$1" runs_on sh_json
  if [ "$SELFHOSTED" = true ]; then runs_on="$RUNS_ON_SELF"; else runs_on=$(fallback_json); fi
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      printf 'runs-on=%s\n' "$runs_on"
      printf 'reason=%s\n' "$REASON"
      printf 'selfhosted=%s\n' "$SELFHOSTED"
    } >> "$GITHUB_OUTPUT"
  fi
  if [ "$SELFHOSTED" = true ]; then sh_json=true; else sh_json=false; fi
  local human="$PROG: runs-on=$runs_on reason=$REASON (event=${EVENT_NAME:-?} repo=${REPO:-?})"
  local summary
  if command -v jq >/dev/null 2>&1; then
    summary=$(jq -nc --arg reason "$REASON" --arg event "$EVENT_NAME" --arg repo "$REPO" \
      --argjson runs_on "$runs_on" --argjson sh "$sh_json" \
      --argjson online "$ONLINE" --argjson idle "$IDLE" --argjson busy "$BUSY" --argjson rc "$rc" \
      '{schema:"select-runner/v1",selfhosted:$sh,runs_on:$runs_on,reason:$reason,event:$event,repo:$repo,online:$online,idle:$idle,busy:$busy,exit_code:$rc}')
  else
    summary="{\"schema\":\"select-runner/v1\",\"selfhosted\":$sh_json,\"runs_on\":$runs_on,\"reason\":\"$REASON\",\"exit_code\":$rc}"
  fi
  if [ "$JSON_ONLY" = 1 ]; then echo "$human" >&2; else echo "$human"; fi
  echo "$summary"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "### Runner picker"
      echo
      echo "| runs-on | reason | self-hosted | online | idle | busy |"
      echo "|---|---|---|---|---|---|"
      echo "| \`$runs_on\` | \`$REASON\` | $sh_json | $ONLINE | $IDLE | $BUSY |"
    } >> "$GITHUB_STEP_SUMMARY"
  fi
  exit "$rc"
}

fallback() { SELFHOSTED=false; REASON="$1"; finish "${2:-0}"; }

# ---- validation (64) -------------------------------------------------------
[ "${BAD_ARG:-0}" = 1 ] && fallback usage 64
if [ -n "$TOKEN" ] && [ "${GITHUB_ACTIONS:-}" = true ]; then printf '::add-mask::%s\n' "$TOKEN"; fi
case "$REPO" in
  */*/* | */ | /* | "" ) echo "$PROG: REPO must be owner/repo" >&2; fallback invalid-repo 64 ;;
  *[!A-Za-z0-9._/-]*) echo "$PROG: REPO has invalid characters" >&2; fallback invalid-repo 64 ;;
  */*) ;;
  *) echo "$PROG: REPO must be owner/repo" >&2; fallback invalid-repo 64 ;;
esac
[ -n "$EVENT_NAME" ] || { echo "$PROG: EVENT_NAME is required" >&2; fallback invalid-event 64; }
case "$TIMEOUT" in "" | *[!0-9]* | 0) echo "$PROG: TIMEOUT must be a positive integer of seconds" >&2; fallback invalid-timeout 64 ;; esac
case "$RETRIES" in "" | *[!0-9]* | 0) echo "$PROG: RETRIES must be a positive integer" >&2; fallback invalid-retries 64 ;; esac
case "$MAX_WAIT" in "" | *[!0-9]*) echo "$PROG: MAX_WAIT must be an integer" >&2; fallback invalid-max-wait 64 ;; esac
case "$(lower "$PREFER_QUEUE")" in true | false) ;; *) echo "$PROG: PREFER_QUEUE must be true or false" >&2; fallback invalid-prefer-queue 64 ;; esac
PREFER_QUEUE=$(lower "$PREFER_QUEUE")
command -v jq >/dev/null 2>&1 || { echo "$PROG: jq is required" >&2; fallback no-jq 0; }
REQ=$(printf '%s' "$LABELS" | jq -Rsc 'split(",")|map(gsub("^\\s+|\\s+$";"")|ascii_downcase|select(length>0))|unique')
[ "$REQ" != "[]" ] || { echo "$PROG: LABELS must not be empty" >&2; fallback invalid-labels 64; }
RUNS_ON_SELF=$(printf '%s' "$LABELS" | jq -Rsc 'split(",")|map(gsub("^\\s+|\\s+$";"")|select(length>0))|map(select(ascii_downcase!="self-hosted"))|["self-hosted"]+.')

# ---- (a) event trust -------------------------------------------------------
trusted=0
for e in $TRUSTED_EVENTS; do [ "$e" = "$EVENT_NAME" ] && trusted=1; done
[ "$trusted" = 1 ] || fallback untrusted-event
if [ "$EVENT_NAME" = pull_request ]; then
  [ -n "$HEAD_REPO" ] && [ "$(lower "$HEAD_REPO")" = "$(lower "$REPO")" ] || fallback fork-pr
fi

# ---- (b) token -------------------------------------------------------------
[ -n "$TOKEN" ] || fallback no-token

# ---- (c) API with retries --------------------------------------------------
WORK=$(mktemp -d "${TMPDIR:-/tmp}/select-runner.XXXXXX") || fallback tmp-error
trap 'rm -rf "$WORK"' EXIT

# api_get <url>: body in $WORK/body. Sets LAST_ERR to a reason slug on failure; returns 0 on 200.
api_get() {
  local url="$1" attempt=1 code rc ra wait delay
  while :; do
    : > "$WORK/hdr"; : > "$WORK/body"
    code=$(printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" | curl -sS -K - --max-time "$TIMEOUT" \
      -D "$WORK/hdr" -o "$WORK/body" -w '%{http_code}' \
      -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
      -A "$PROG/$VERSION" "$url" 2>/dev/null)
    rc=$?
    ra=$(tr -d '\r' < "$WORK/hdr" | sed -n 's/^[Rr]etry-[Aa]fter: *\([0-9][0-9]*\).*/\1/p' | tail -1)
    local remaining
    remaining=$(tr -d '\r' < "$WORK/hdr" | sed -n 's/^[Xx]-[Rr]ate[Ll]imit-[Rr]emaining: *\([0-9][0-9]*\).*/\1/p' | tail -1)
    if [ "$rc" -ne 0 ]; then
      if [ "$rc" -eq 28 ]; then LAST_ERR=timeout; else LAST_ERR=network-error; fi
    else
      case "$code" in
        200) return 0 ;;
        429) LAST_ERR=rate-limited ;;
        403) if [ -n "$ra" ] || [ "$remaining" = 0 ]; then LAST_ERR=rate-limited; else LAST_ERR=api-403; return 1; fi ;;
        401 | 404 | 400 | 422) LAST_ERR="api-$code"; return 1 ;;
        5??) LAST_ERR="api-$code" ;;
        *) LAST_ERR="api-${code:-000}"; return 1 ;;
      esac
    fi
    [ "$attempt" -lt "$RETRIES" ] || return 1
    delay=$((1 << (attempt - 1)))
    wait="$delay.$(printf '%03d' $((RANDOM % 1000)))"
    if [ -n "$ra" ]; then
      [ "$ra" -le "$MAX_WAIT" ] || return 1
      wait="$ra"
    fi
    "$SLEEP" "$wait" 2>/dev/null || true
    attempt=$((attempt + 1))
  done
}

ALL="[]"
page=1
while [ "$page" -le 20 ]; do
  api_get "$API_URL/repos/$REPO/actions/runners?per_page=100&page=$page" || fallback "$LAST_ERR"
  if ! jq -e '(.runners|type)=="array"' "$WORK/body" >/dev/null 2>&1; then fallback bad-json; fi
  n=$(jq '.runners|length' "$WORK/body")
  ALL=$(jq -c --slurpfile p "$WORK/body" '. + $p[0].runners' <<<"$ALL") || fallback bad-json
  [ "$n" -ge 100 ] || break
  page=$((page + 1))
done

# ---- (d) selection ---------------------------------------------------------
STATS=$(jq -c --argjson req "$REQ" '
  [ .[] | select(type=="object" and .status=="online")
        | select(((.labels // []) | map((.name // "") | ascii_downcase)) as $l | all($req[]; . as $r | $l | index($r) != null)) ]
  | {online: length, idle: (map(select(.busy != true)) | length), busy: (map(select(.busy == true)) | length)}' <<<"$ALL") || fallback bad-json
ONLINE=$(jq '.online' <<<"$STATS"); IDLE=$(jq '.idle' <<<"$STATS"); BUSY=$(jq '.busy' <<<"$STATS")

if [ "$ONLINE" -eq 0 ]; then fallback no-runner-online; fi
if [ "$IDLE" -gt 0 ]; then SELFHOSTED=true; REASON=idle-runner; finish 0; fi
if [ "$PREFER_QUEUE" = true ]; then SELFHOSTED=true; REASON=queue; finish 0; fi
fallback all-busy
