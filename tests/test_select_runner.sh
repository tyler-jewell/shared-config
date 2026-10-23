#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034  # test snippets are single-quoted for eval
# Tests for scripts/select-runner.sh using a fake curl (tests/fixtures/curl). No network.
# Usage: bash tests/test_select_runner.sh   (also invoked by tests/run.sh)
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); ROOT=$(cd "$HERE/.." && pwd)
SR="$ROOT/scripts/select-runner.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
t()   { if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }
section() { printf '\n== select-runner: %s\n' "$1"; }
W=$(mktemp -d "${TMPDIR:-/tmp}/sr-tests.XXXXXX"); trap 'rm -rf "$W"' EXIT
D="$W/curl"; GO="$W/github_output"; GS="$W/summary"
SENTINEL="ghp_SENTINEL_do_not_leak_0123456789"
mkdir -p "$W/bin"; cp "$HERE/fixtures/curl" "$W/bin/curl"; printf '#!/bin/sh\necho "$@" >> "%s/sleeps.log"\n' "$W" > "$W/bin/fakesleep"; chmod +x "$W/bin/fakesleep"

newstate() { rm -rf "$D"; mkdir -p "$D"; : > "$GO"; : > "$GS"; : > "$W/sleeps.log"; }
# rn <name> <status> <busy> <label,label,...> -> one runner JSON object
rn() { jq -nc --arg n "$1" --arg s "$2" --argjson b "$3" --arg l "$4" '{id:1,name:$n,os:"macOS",status:$s,busy:$b,labels:($l|split(",")|map({name:.,type:"custom"}))}'; }
# body <runner-json>... -> API response body
body() { printf '%s\n' "$@" | jq -sc '{total_count:length,runners:.}'; }
setdefault() { printf '%s\n' "$1" > "$D/default.body"; }
SL="self-hosted,macOS,ARM64,mac-studio"
# run_sr [VAR=val ...]: defaults = trusted push on same repo with token
OUT=""; ERR=""; RC=0
run_sr() {
  OUT=$(env -u GITHUB_ACTIONS PATH="$W/bin:$PATH" FAKE_CURL_DIR="$D" GITHUB_OUTPUT="$GO" GITHUB_STEP_SUMMARY="$GS" \
    SELECT_RUNNER_SLEEP="$W/bin/fakesleep" GH_TOKEN="$SENTINEL" REPO=tyler-jewell/r EVENT_NAME=push \
    API_URL=https://api.example.test "$@" bash "$SR" 2>"$W/err"); RC=$?; ERR=$(cat "$W/err")
}
last() { printf '%s\n' "$OUT" | tail -1; }
j() { last | jq -r "$1"; }
go() { sed -n "s/^$1=//p" "$GO"; }
calls() { wc -l < "$D/calls.log" 2>/dev/null | tr -d ' ' || echo 0; }
decide() { # decide <reason> <selfhosted>
  local r="$1" sh="$2"
  t "reason=$r selfhosted=$sh exit 0" "[ \$RC -eq 0 ] && [ \"\$(j .reason)\" = '$r' ] && [ \"\$(j .selfhosted)\" = '$sh' ] && [ \"\$(go reason)\" = '$r' ] && [ \"\$(go selfhosted)\" = '$sh' ]"
}
IDLE_BODY=$(body "$(rn studio online false "$SL")")

section "usage, help, version"
OUT=$(bash "$SR" --help); RC=$?; t "--help exits 0 and documents exit codes" '[ $RC -eq 0 ] && grep -q "Exit codes" <<<"$OUT"'
OUT=$(bash "$SR" --version); RC=$?; t "--version" '[ $RC -eq 0 ] && grep -q "^select-runner [0-9]" <<<"$OUT"'
newstate; run_sr REPO=; t "missing REPO => exit 64, fallback still emitted" '[ $RC -eq 64 ] && [ "$(go runs-on)" = "\"ubuntu-latest\"" ] && [ "$(go selfhosted)" = false ] && [ "$(go reason)" = invalid-repo ]'
newstate; run_sr REPO=justname; t "REPO without slash => 64" '[ $RC -eq 64 ]'
newstate; run_sr 'REPO=a/b;rm'; t "REPO with bad chars => 64" '[ $RC -eq 64 ]'
newstate; run_sr EVENT_NAME=; t "missing EVENT_NAME => 64" '[ $RC -eq 64 ] && [ "$(go selfhosted)" = false ]'
newstate; run_sr RETRIES=abc; t "bad RETRIES => 64" '[ $RC -eq 64 ]'
newstate; run_sr TIMEOUT=0; t "bad TIMEOUT => 64" '[ $RC -eq 64 ]'
newstate; run_sr LABELS=" , "; t "empty LABELS => 64" '[ $RC -eq 64 ]'
newstate; run_sr PREFER_QUEUE=maybe; t "bad PREFER_QUEUE => 64" '[ $RC -eq 64 ]'
OUT=$(env REPO=a/b EVENT_NAME=push GH_TOKEN=x bash "$SR" --bogus 2>/dev/null); RC=$?; t "unknown flag => 64 with fallback JSON" '[ $RC -eq 64 ] && [ "$(last | jq -r .selfhosted)" = false ]'

section "event trust (no API call may happen)"
newstate; setdefault "$IDLE_BODY"
run_sr EVENT_NAME=pull_request HEAD_REPO=evil/fork; decide fork-pr false; t "fork PR makes no API call" '[ ! -e "$D/calls.log" ]'
newstate; setdefault "$IDLE_BODY"; run_sr EVENT_NAME=pull_request HEAD_REPO=; decide fork-pr false
newstate; setdefault "$IDLE_BODY"; run_sr EVENT_NAME=pull_request HEAD_REPO=tyler-jewell/r-other; decide fork-pr false
for ev in issue_comment pull_request_target workflow_run issues release fork; do
  newstate; setdefault "$IDLE_BODY"; run_sr EVENT_NAME=$ev HEAD_REPO=tyler-jewell/r; decide untrusted-event false
  t "$ev: no API call" '[ ! -e "$D/calls.log" ]'
done
newstate; setdefault "$IDLE_BODY"; run_sr EVENT_NAME=pull_request HEAD_REPO=tyler-jewell/r; decide idle-runner true
newstate; setdefault "$IDLE_BODY"; run_sr EVENT_NAME=pull_request HEAD_REPO=Tyler-Jewell/R; decide idle-runner true
for ev in push schedule workflow_dispatch merge_group; do newstate; setdefault "$IDLE_BODY"; run_sr EVENT_NAME=$ev; decide idle-runner true; done
newstate; setdefault "$IDLE_BODY"; run_sr GH_TOKEN=; decide no-token false; t "empty token: no API call" '[ ! -e "$D/calls.log" ]'

section "decision and output format"
newstate; setdefault "$IDLE_BODY"; run_sr
t "runs-on in GITHUB_OUTPUT is compact JSON array" '[ "$(go runs-on)" = "[\"self-hosted\",\"mac-studio\"]" ]'
t "GITHUB_OUTPUT has exactly 3 key=value lines" '[ "$(wc -l < "$GO" | tr -d " ")" = 3 ] && ! grep -qv "^[a-z-]*=" "$GO"'
t "stdout: human line then one-line JSON summary" '[ "$(printf "%s\n" "$OUT" | wc -l | tr -d " ")" = 2 ] && printf "%s\n" "$OUT" | head -1 | grep -q "^select-runner: runs-on=" && [ "$(j .schema)" = select-runner/v1 ]'
t "summary counts" '[ "$(j .online)" = 1 ] && [ "$(j .idle)" = 1 ] && [ "$(j .busy)" = 0 ]'
t "GITHUB_STEP_SUMMARY table written" 'grep -q "idle-runner" "$GS" && grep -q "^| runs-on" "$GS"'
t "auth header sent (via stdin config, not argv)" 'grep -q "auth=yes" "$D/calls.log"'
t "request URL has per_page=100" 'grep -q "/repos/tyler-jewell/r/actions/runners?per_page=100&page=1" "$D/calls.log"'
newstate; setdefault "$IDLE_BODY"; run_sr LABELS="macOS, mac-studio"
t "runs-on includes all given labels once, plus self-hosted" '[ "$(go runs-on)" = "[\"self-hosted\",\"macOS\",\"mac-studio\"]" ]'
newstate; setdefault "$IDLE_BODY"; run_sr LABELS="self-hosted,mac-studio"; t "self-hosted label not duplicated" '[ "$(go runs-on)" = "[\"self-hosted\",\"mac-studio\"]" ]'
newstate; setdefault "$IDLE_BODY"; run_sr FALLBACK=ubuntu-24.04 GH_TOKEN=; t "custom fallback string" '[ "$(go runs-on)" = "\"ubuntu-24.04\"" ]'
newstate; run_sr FALLBACK='["self-hosted","linux"]' GH_TOKEN=; t "JSON array fallback passes through" '[ "$(go runs-on)" = "[\"self-hosted\",\"linux\"]" ]'
newstate; setdefault "$IDLE_BODY"; OUT=$(env -u GITHUB_ACTIONS -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY PATH="$W/bin:$PATH" FAKE_CURL_DIR="$D" SELECT_RUNNER_SLEEP="$W/bin/fakesleep" GH_TOKEN=$SENTINEL REPO=o/r EVENT_NAME=push API_URL=x bash "$SR" --json 2>"$W/err"); RC=$?
t "--json: only the JSON line on stdout" '[ $RC -eq 0 ] && [ "$(printf "%s\n" "$OUT" | wc -l | tr -d " ")" = 1 ] && jq -e .selfhosted <<<"$OUT" >/dev/null'
t "works without GITHUB_OUTPUT/STEP_SUMMARY set" '[ $RC -eq 0 ]'

section "runner states and labels"
newstate; setdefault "$(body "$(rn a offline false "$SL")")"; run_sr; decide no-runner-online false
newstate; setdefault "$(body "$(rn a online false "self-hosted,macOS,other")")"; run_sr; decide no-runner-online false; t "wrong label => online=0" '[ "$(j .online)" = 0 ]'
newstate; setdefault "$(body "$(rn a online true "$SL")")"; run_sr; decide all-busy false
newstate; setdefault "$(body "$(rn a online true "$SL")")"; run_sr PREFER_QUEUE=true; decide queue true
newstate; setdefault "$(body "$(rn a online true "$SL")")"; run_sr PREFER_QUEUE=TRUE; decide queue true
newstate; setdefault "$(body "$(rn a offline false "$SL")")"; run_sr PREFER_QUEUE=true; decide no-runner-online false
newstate; setdefault "$(body "$(rn a online true "$SL")" "$(rn b online false "$SL")")"; run_sr; decide idle-runner true; t "one idle of two" '[ "$(j .busy)" = 1 ] && [ "$(j .idle)" = 1 ]'
newstate; setdefault "$(body "$(rn a offline false "$SL")" "$(rn b online true "$SL")")"; run_sr; decide all-busy false
newstate; setdefault '{"total_count":0,"runners":[]}'; run_sr; decide no-runner-online false
newstate; setdefault "$(body "$(rn a online false "mac-studio,macOS,ARM64,self-hosted")")"; run_sr LABELS="macos,arm64,mac-studio"; decide idle-runner true
newstate; setdefault "$(body "$(rn a online false "mac-studio")")"; run_sr LABELS="mac-studio,gpu"; decide no-runner-online false

section "pagination"
r100=""; for i in $(seq 1 100); do r100="$r100$(rn "x$i" online true "linux")"$'\n'; done
# shellcheck disable=SC2046
P1=$(printf '%s' "$r100" | jq -sc '{total_count:101,runners:.}')
newstate; printf '%s\n' "$P1" > "$D/page.1.body"; body "$(rn studio online false "$SL")" > "$D/page.2.body"
run_sr; decide idle-runner true; t "target runner on page 2 found; exactly 2 calls" '[ "$(calls)" = 2 ] && grep -q "page=2" "$D/calls.log"'
newstate; setdefault "$IDLE_BODY"; run_sr; t "short first page: single call" '[ "$(calls)" = 1 ]'
newstate; printf '%s\n' "$P1" > "$D/page.1.body"; echo 500 > "$D/resp.2.code"; run_sr RETRIES=1; decide api-500 false
newstate; printf '%s\n' "$P1" > "$D/page.1.body"; printf '%s\n' "$P1" > "$D/page.2.body"; printf '%s\n' "$P1" > "$D/default.body"; run_sr; t "page cap (20) terminates and falls back" '[ $RC -eq 0 ] && [ "$(calls)" -le 20 ]'

section "API failures always fall back with exit 0"
for c in 401 403 404; do newstate; echo "$c" > "$D/default.code"; echo '{"message":"x"}' > "$D/default.body"; run_sr; decide "api-$c" false; t "$c: not retried" '[ "$(calls)" = 1 ]'; done
newstate; echo 500 > "$D/default.code"; run_sr; decide api-500 false; t "500: retried 3 times with backoff sleeps" '[ "$(calls)" = 3 ] && [ "$(wc -l < "$W/sleeps.log" | tr -d " ")" = 2 ]'
t "backoff grows exponentially (1.x then 2.x)" 'sed -n 1p "$W/sleeps.log" | grep -q "^1\.[0-9][0-9][0-9]$" && sed -n 2p "$W/sleeps.log" | grep -q "^2\.[0-9][0-9][0-9]$"'
newstate; echo 500 > "$D/default.code"; run_sr RETRIES=5; t "RETRIES=5 => 5 attempts" '[ "$(calls)" = 5 ]'
newstate; echo 503 > "$D/resp.1.code"; setdefault "$IDLE_BODY"; run_sr; decide idle-runner true; t "transient 503 then success" '[ "$(calls)" = 2 ]'
newstate; echo 429 > "$D/default.code"; printf 'HTTP/2 429\r\nRetry-After: 7\r\n' > "$D/default.hdr"; run_sr; decide rate-limited false
t "429: Retry-After honoured exactly" 'grep -qx "7" "$W/sleeps.log"'
newstate; echo 429 > "$D/resp.1.code"; printf 'Retry-After: 2\r\n' > "$D/resp.1.hdr"; setdefault "$IDLE_BODY"; run_sr; decide idle-runner true; t "429 then success waits 2s" 'grep -qx "2" "$W/sleeps.log"'
newstate; echo 429 > "$D/default.code"; printf 'Retry-After: 3600\r\n' > "$D/default.hdr"; run_sr; decide rate-limited false; t "huge Retry-After: give up without sleeping" '[ "$(calls)" = 1 ] && [ ! -s "$W/sleeps.log" ]'
newstate; echo 403 > "$D/default.code"; printf 'Retry-After: 4\r\n' > "$D/default.hdr"; run_sr; decide rate-limited false; t "secondary rate limit (403+Retry-After) retried" '[ "$(calls)" = 3 ]'
newstate; echo 403 > "$D/default.code"; printf 'x-ratelimit-remaining: 0\r\n' > "$D/default.hdr"; run_sr; decide rate-limited false
newstate; echo curl:28 > "$D/default.code"; run_sr; decide timeout false; t "timeout retried" '[ "$(calls)" = 3 ]'
newstate; echo curl:6 > "$D/default.code"; run_sr; decide network-error false
newstate; echo curl:6 > "$D/resp.1.code"; setdefault "$IDLE_BODY"; run_sr; decide idle-runner true
newstate; echo 'not json {' > "$D/default.body"; run_sr; decide bad-json false
newstate; echo '{"runners":"nope"}' > "$D/default.body"; run_sr; decide bad-json false
newstate; echo '[1,2]' > "$D/default.body"; run_sr; decide bad-json false
newstate; : > "$D/default.body"; run_sr; decide bad-json false
newstate; echo '{"runners":[null,1,"x",{"status":"online"}]}' > "$D/default.body"; run_sr; decide no-runner-online false; t "odd runner entries tolerated" '[ $RC -eq 0 ]'

section "token never leaks"
for s in "ok" "401" "500" "429" "badjson" "forkpr"; do
  newstate
  case $s in
    ok) setdefault "$IDLE_BODY"; run_sr ;;
    401) echo 401 > "$D/default.code"; run_sr ;;
    500) echo 500 > "$D/default.code"; run_sr ;;
    429) echo 429 > "$D/default.code"; run_sr ;;
    badjson) echo '{' > "$D/default.body"; run_sr ;;
    forkpr) run_sr EVENT_NAME=pull_request HEAD_REPO=x/y ;;
  esac
  t "sentinel absent from stdout/stderr/outputs/summary ($s)" '! grep -q "$SENTINEL" <<<"$OUT$ERR" && ! grep -q "$SENTINEL" "$GO" "$GS"'
done
newstate; setdefault "$IDLE_BODY"; run_sr; t "token only reached the fake curl via stdin config" 'grep -q "$SENTINEL" "$D/last.config" && ! grep -q "$SENTINEL" "$D/calls.log"'
newstate; setdefault "$IDLE_BODY"; run_sr GITHUB_ACTIONS=true; t "in Actions: token masked via ::add-mask::, and nowhere else" '[ "$(printf "%s\n" "$OUT$ERR" | grep -c "$SENTINEL")" = 1 ] && grep -qx "::add-mask::$SENTINEL" <<<"$OUT"'
t "script never enables xtrace or echoes the token variable" '! grep -nE "set -[a-z]*x|echo[^|]*\\\$TOKEN|printf[^|]*\\\$TOKEN" "$SR" | grep -v "add-mask\|Authorization\|set +x"'

section "static"
if command -v shellcheck >/dev/null 2>&1; then t "shellcheck: select-runner + tests + fake curl" 'shellcheck -x "$SR" "$HERE/test_select_runner.sh" "$HERE/fixtures/curl"'; else ok "shellcheck not installed: skipped"; fi
t "bash 3.2-safe syntax (no mapfile/assoc arrays/&>>)" '! grep -nE "mapfile|readarray|declare -A|\\$\\{[a-z_A-Z]+(,,|\\^\\^)" "$SR" && bash -n "$SR"'

printf '\nselect-runner: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
