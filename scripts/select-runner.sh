#!/usr/bin/env bash
# select-runner.sh: decide `runs-on` for CI jobs: prefer a self-hosted runner when one is
# available, otherwise fall back to a GitHub-hosted label. Never fails the pipeline because of
# the picker: every decision exits 0 and every error degrades to the fallback.
#
# Inputs (environment only; secrets are never taken from flags):
#   MODE          studio | hosted | auto (default hosted; unset/empty = hosted)
#                   studio: trusted events go to the self-hosted labels, no API call, no token
#                   hosted: always the fallback
#                   auto:   ask the REST API whether a matching runner is online/idle (needs GH_TOKEN)
#   OS_TARGET     macos (default) | linux: which label set `runs-on`/`reason`/`selfhosted` describe
#   GH_TOKEN      (auto mode only) fine-grained PAT with Administration: read; empty => fallback
#   REPO          owner/repo (required)
#   EVENT_NAME    github.event_name (required)
#   HEAD_REPO     PR head repo full name (pull_request events; empty => treated as fork)
#   LABELS        comma list overriding the labels of OS_TARGET (default: macos => mac-studio,
#                 linux => mac-studio-linux); the other OS keeps its default
#   FALLBACK      runs-on when not self-hosted (default: ubuntu-latest; the fallback is Linux)
#   PREFER_QUEUE  true => self-hosted even when every matching runner is busy (default: false)
#   TIMEOUT       per API call, seconds, "10" or "10s" (default: 10)
#   RETRIES       max attempts per API call (default: 3), exponential backoff with jitter
#   API_URL       default https://api.github.com (tests)
#   TRUSTED_EVENTS space list (default: push workflow_dispatch schedule merge_group pull_request)
#   MAX_WAIT      cap in seconds on a single Retry-After wait (default: 30)
#   GITHUB_OUTPUT / GITHUB_STEP_SUMMARY: written when set.
# Outputs: runs-on/reason/selfhosted for OS_TARGET, plus macos and linux (runs-on JSON for each
# OS, for matrices) and mode. Untrusted events and fork PRs ALWAYS get the fallback, in every mode.
# Exit codes: 0 decision made (including every fallback); 64 invalid usage/env (fallback is
# still written to $GITHUB_OUTPUT so pipelines keep working).
set +x
set -u
VERSION="1.1.0"
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
LABELS="${LABELS:-}"
MODE="${MODE:-hosted}"
OS_TARGET="${OS_TARGET:-macos}"
FALLBACK="${FALLBACK:-ubuntu-latest}"
PREFER_QUEUE="${PREFER_QUEUE:-false}"
TIMEOUT="${TIMEOUT:-10}"
RETRIES="${RETRIES:-3}"
API_URL="${API_URL:-https://api.github.com}"
TRUSTED_EVENTS="${TRUSTED_EVENTS:-push workflow_dispatch schedule merge_group pull_request}"
MAX_WAIT="${MAX_WAIT:-30}"
SLEEP="${SELECT_RUNNER_SLEEP:-sleep}"
TIMEOUT="${TIMEOUT%s}"

# Per-OS decision state (macos, linux). OS_TARGET's values are what the single-value outputs report.
SH_macos=false; SH_linux=false
RS_macos=""; RS_linux=""
RO_macos="[]"; RO_linux="[]"
ON_macos=0; ON_linux=0; ID_macos=0; ID_linux=0; BU_macos=0; BU_linux=0
SELFHOSTED=false; REASON=""; ONLINE=0; IDLE=0; BUSY=0
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
  local rc="$1" runs_on sh_json fb ro_macos ro_linux
  fb=$(fallback_json)
  if [ "$SH_macos" = true ]; then ro_macos="$RO_macos"; else ro_macos="$fb"; fi
  if [ "$SH_linux" = true ]; then ro_linux="$RO_linux"; else ro_linux="$fb"; fi
  if [ "$OS_TARGET" = linux ]; then
    SELFHOSTED=$SH_linux; REASON=$RS_linux; runs_on=$ro_linux; ONLINE=$ON_linux; IDLE=$ID_linux; BUSY=$BU_linux
  else
    SELFHOSTED=$SH_macos; REASON=$RS_macos; runs_on=$ro_macos; ONLINE=$ON_macos; IDLE=$ID_macos; BUSY=$BU_macos
  fi
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      printf 'runs-on=%s\n' "$runs_on"
      printf 'reason=%s\n' "$REASON"
      printf 'selfhosted=%s\n' "$SELFHOSTED"
      printf 'macos=%s\n' "$ro_macos"
      printf 'linux=%s\n' "$ro_linux"
      printf 'mode=%s\n' "${MODE_OUT:-$MODE}"
    } >> "$GITHUB_OUTPUT"
  fi
  if [ "$SELFHOSTED" = true ]; then sh_json=true; else sh_json=false; fi
  local human="$PROG: runs-on=$runs_on reason=$REASON (event=${EVENT_NAME:-?} repo=${REPO:-?})"
  local summary
  if command -v jq >/dev/null 2>&1; then
    summary=$(jq -nc --arg reason "$REASON" --arg event "$EVENT_NAME" --arg repo "$REPO" \
      --argjson runs_on "$runs_on" --argjson sh "$sh_json" --arg mode "${MODE_OUT:-$MODE}" --arg os "$OS_TARGET" \
      --argjson macos "$ro_macos" --argjson linux "$ro_linux" \
      --argjson online "$ONLINE" --argjson idle "$IDLE" --argjson busy "$BUSY" --argjson rc "$rc" \
      '{schema:"select-runner/v1",mode:$mode,os:$os,selfhosted:$sh,runs_on:$runs_on,macos:$macos,linux:$linux,reason:$reason,event:$event,repo:$repo,online:$online,idle:$idle,busy:$busy,exit_code:$rc}')
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

# fallback <reason> [exit]: both OS targets go to the fallback.
fallback() { SH_macos=false; SH_linux=false; RS_macos="$1"; RS_linux="$1"; finish "${2:-0}"; }

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
MODE=$(lower "$MODE"); OS_TARGET=$(lower "$OS_TARGET")
case "$MODE" in studio | hosted | auto) ;; *) echo "$PROG: MODE must be studio, hosted or auto" >&2; fallback invalid-mode 64 ;; esac
case "$OS_TARGET" in macos | linux) ;; *) echo "$PROG: OS_TARGET must be macos or linux" >&2; fallback invalid-os 64 ;; esac
if [ -n "$LABELS" ] && [ "$(printf '%s' "$LABELS" | jq -Rsc 'split(",")|map(gsub("^\\s+|\\s+$";"")|select(length>0))|length')" = 0 ]; then
  echo "$PROG: LABELS must not be only separators" >&2; fallback invalid-labels 64
fi
# labels_for <os>: comma list for that OS (LABELS overrides only OS_TARGET)
labels_for() {
  if [ "$1" = "$OS_TARGET" ] && [ -n "$LABELS" ]; then printf '%s' "$LABELS"
  elif [ "$1" = linux ]; then printf 'mac-studio-linux'
  else printf 'mac-studio'; fi
}
for os in macos linux; do
  L=$(labels_for "$os")
  ro=$(printf '%s' "$L" | jq -Rsc 'split(",")|map(gsub("^\\s+|\\s+$";"")|select(length>0))|map(select(ascii_downcase!="self-hosted"))|["self-hosted"]+.')
  if [ "$os" = macos ]; then RO_macos="$ro"; else RO_linux="$ro"; fi
done

# ---- (a) event trust -------------------------------------------------------
trusted=0
for e in $TRUSTED_EVENTS; do [ "$e" = "$EVENT_NAME" ] && trusted=1; done
[ "$trusted" = 1 ] || fallback untrusted-event
if [ "$EVENT_NAME" = pull_request ]; then
  if [ -z "$HEAD_REPO" ] || [ "$(lower "$HEAD_REPO")" != "$(lower "$REPO")" ]; then
    fallback fork-pr
  fi
fi

# ---- (b) mode (token-free switch) ------------------------------------------
case "$MODE" in
  hosted) fallback mode-hosted ;;
  studio) SH_macos=true; SH_linux=true; RS_macos=mode-studio; RS_linux=mode-studio; finish 0 ;;
esac

# ---- (c0) auto mode needs the token ------------------------------------------
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

# ---- (d) selection (auto mode), evaluated for both OS label sets ---------------
for os in macos linux; do
  REQ=$(labels_for "$os" | jq -Rsc 'split(",")|map(gsub("^\\s+|\\s+$";"")|ascii_downcase|select(length>0))|unique')
  STATS=$(jq -c --argjson req "$REQ" '
    [ .[] | select(type=="object" and .status=="online")
          | select(((.labels // []) | map((.name // "") | ascii_downcase)) as $l | all($req[]; . as $r | $l | index($r) != null)) ]
    | {online: length, idle: (map(select(.busy != true)) | length), busy: (map(select(.busy == true)) | length)}' <<<"$ALL") || fallback bad-json
  on=$(jq '.online' <<<"$STATS"); id=$(jq '.idle' <<<"$STATS"); bu=$(jq '.busy' <<<"$STATS")
  sh=false
  if [ "$on" -eq 0 ]; then r=no-runner-online
  elif [ "$id" -gt 0 ]; then sh=true; r=idle-runner
  elif [ "$PREFER_QUEUE" = true ]; then sh=true; r=queue
  else r=all-busy; fi
  if [ "$os" = macos ]; then SH_macos=$sh; RS_macos=$r; ON_macos=$on; ID_macos=$id; BU_macos=$bu
  else SH_linux=$sh; RS_linux=$r; ON_linux=$on; ID_linux=$id; BU_linux=$bu; fi
done
finish 0
