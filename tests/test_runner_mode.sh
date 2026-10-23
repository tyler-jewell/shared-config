#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034  # test snippets are single-quoted for eval
# Tests for bin/runner-mode with a fake gh (tests/fixtures/gh-vars). No network.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); ROOT=$(cd "$HERE/.." && pwd)
RM="$ROOT/bin/runner-mode"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
t()   { if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }
printf '\n== runner-mode\n'
W=$(mktemp -d "${TMPDIR:-/tmp}/rm-tests.XXXXXX"); trap 'rm -rf "$W"' EXIT
D="$W/state"; mkdir -p "$W/cfg"
OUT=""; RC=0
rm_() { OUT=$(GH="$HERE/fixtures/gh-vars" FAKE_RM_DIR="$D" REPO_POLICY_CONFIG_DIR="$W/cfg" bash "$RM" "$@" 2>"$W/err"); RC=$?; }
fresh() { rm -rf "$D"; mkdir -p "$D"; : > "$W/cfg/skip.txt"
  cat > "$D/repos.json" <<'JSON'
[{"full_name":"tyler-jewell/a1","owner":{"login":"tyler-jewell"},"archived":false},
 {"full_name":"tyler-jewell/a2","owner":{"login":"tyler-jewell"},"archived":false},
 {"full_name":"tyler-jewell/skipme","owner":{"login":"tyler-jewell"},"archived":false},
 {"full_name":"tyler-jewell/old","owner":{"login":"tyler-jewell"},"archived":true},
 {"full_name":"tyler-jewell/flag-seeker","owner":{"login":"tyler-jewell"},"archived":false},
 {"full_name":"Flag-Seeker/flagseeker","owner":{"login":"Flag-Seeker"},"archived":false}]
JSON
}
writes() { if [ -e "$D/calls.log" ]; then grep -c '^variable set' "$D/calls.log" || true; else echo 0; fi; }

OUT=$(bash "$RM" --help); RC=$?; t "--help exit 0 documents exit codes" '[ $RC -eq 0 ] && grep -q "Exit codes" <<<"$OUT"'
OUT=$(bash "$RM" --version); t "--version" 'grep -q "^runner-mode [0-9]" <<<"$OUT"'
fresh; rm_; t "no command => 64" '[ $RC -eq 64 ]'
rm_ set; t "set without mode => 64" '[ $RC -eq 64 ]'
rm_ set bogus tyler-jewell/a1; t "invalid mode => 64, no write" '[ $RC -eq 64 ] && [ ! -e "$D/calls.log" ]'
rm_ set hosted; t "set without target => 64" '[ $RC -eq 64 ]'
rm_ set hosted tyler-jewell/a1 --all-active; t "target and --all-active => 64" '[ $RC -eq 64 ]'
rm_ set hosted notarepo; t "bad target shape => 64" '[ $RC -eq 64 ]'
rm_ frob; t "unknown command => 64" '[ $RC -eq 64 ]'
rm_ get tyler-jewell/a1 --nope; t "unknown flag => 64" '[ $RC -eq 64 ]'

fresh; rm_ get tyler-jewell/a1 --json; t "get unset => ok, value unset" '[ $RC -eq 0 ] && jq -e ".repos[0].before==\"unset\" and .schema==\"runner-mode/v1\"" <<<"$OUT" >/dev/null'
echo studio > "$D/tyler-jewell__a1.var"; rm_ get tyler-jewell/a1 --json; t "get studio" 'jq -e ".repos[0].before==\"studio\"" <<<"$OUT" >/dev/null'
fresh; rm_ set hosted tyler-jewell/a1 --json; t "set from unset => changed, 1 write" '[ $RC -eq 0 ] && jq -e ".repos[0].status==\"changed\" and .repos[0].after==\"hosted\"" <<<"$OUT" >/dev/null && [ "$(writes)" = 1 ] && [ "$(cat "$D/tyler-jewell__a1.var")" = hosted ]'
rm_ set hosted tyler-jewell/a1 --json; t "set same value => unchanged, no extra write" '[ $RC -eq 0 ] && jq -e ".repos[0].status==\"unchanged\"" <<<"$OUT" >/dev/null && [ "$(writes)" = 1 ]'
fresh; rm_ set studio tyler-jewell/a1 --dry-run --json; t "--dry-run: would-change, no write" '[ $RC -eq 0 ] && jq -e ".dry_run==true and .repos[0].status==\"would-change\"" <<<"$OUT" >/dev/null && [ "$(writes)" = 0 ]'
fresh; rm_ set auto tyler-jewell/a1; t "human output without --json" '[ $RC -eq 0 ] && grep -q "changed" <<<"$OUT" && ! jq -e . <<<"$OUT" >/dev/null 2>&1'
fresh; rm_ set hosted Flag-Seeker/flagseeker; t "explicit Flag-Seeker refused (4), no call" '[ $RC -eq 4 ] && [ ! -e "$D/calls.log" ]'
fresh; rm_ set hosted tyler-jewell/flag-seeker; t "explicit flag-seeker repo name refused (4)" '[ $RC -eq 4 ] && [ "$(writes)" = 0 ]'
fresh; rm_ set hosted someoneelse/x; t "wrong owner refused (4)" '[ $RC -eq 4 ] && [ ! -e "$D/calls.log" ]'
fresh; rm_ set hosted someoneelse/x --owner someoneelse; t "--owner override works" '[ $RC -eq 0 ]'
fresh; rm_ set hosted Flag-Seeker/x --owner Flag-Seeker; t "Flag-Seeker refused even with --owner" '[ $RC -eq 4 ]'

fresh; printf 'tyler-jewell/skipme\n' > "$W/cfg/skip.txt"; rm_ set hosted --all-active --json
t "--all-active: a1,a2 changed; skipme/old/flag-seeker/Flag-Seeker never touched" '[ $RC -eq 0 ] && jq -e "([.repos[]|select(.status==\"changed\").repo]|sort)==[\"tyler-jewell/a1\",\"tyler-jewell/a2\"]" <<<"$OUT" >/dev/null && [ "$(writes)" = 2 ] && ! grep -qi "flag-seeker\|flagseeker\|skipme\|old" "$D/calls.log"'
fresh; rm_ list --json; t "list = get --all-active, read-only" '[ $RC -eq 0 ] && [ "$(writes)" = 0 ] && jq -e ".command==\"list\" and (.repos|length)==4" <<<"$OUT" >/dev/null'
fresh; rm_ set studio --all-active --dry-run; t "--all-active --dry-run read-only" '[ $RC -eq 0 ] && [ "$(writes)" = 0 ]'
fresh; touch "$D/tyler-jewell__a1.geterr"; rm_ get --all-active --json; t "gh error on one repo => exit 3, others continue" '[ $RC -eq 3 ] && jq -e "[.repos[].status]|(index(\"error\")!=null and index(\"ok\")!=null)" <<<"$OUT" >/dev/null'
fresh; touch "$D/tyler-jewell__a1.seterr"; rm_ set hosted tyler-jewell/a1; t "write failure => exit 3" '[ $RC -eq 3 ]'
fresh; rm_ set hosted tyler-jewell/a1; t "never prompts (stdin closed)" '[ $RC -eq 0 ]'
if command -v shellcheck >/dev/null 2>&1; then t "shellcheck: runner-mode + test + fake gh" 'shellcheck -x "$RM" "$HERE/test_runner_mode.sh" "$HERE/fixtures/gh-vars"'; fi
printf '\nrunner-mode: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
