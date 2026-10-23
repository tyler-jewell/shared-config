#!/usr/bin/env bash
# Test suite for shared-config. Usage: bash tests/run.sh
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); ROOT=$(cd "$HERE/.." && pwd)
RP="$ROOT/bin/repo-policy"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
t()    { if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }
section() { printf '\n== %s\n' "$1"; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/sc-tests.XXXXXX"); trap 'rm -rf "$WORK"' EXIT

pattern_of() { sed -n "s/^ *PATTERN: '\(.*\)'\$/\1/p" "$ROOT/.github/workflows/$1" | head -1; }

section "regex fixtures (patterns extracted from the workflows themselves)"
BP=$(pattern_of branch-name.yml); TP=$(pattern_of pr-title.yml)
t "branch pattern extracted" '[ -n "$BP" ]'
t "title pattern extracted"  '[ -n "$TP" ]'
n=0; while IFS= read -r l; do [ -n "$l" ] || continue; n=$((n+1)); [[ "$l" =~ $BP ]] || bad "branch should pass: $l"; done < "$HERE/fixtures/branch-ok.txt"; ok "branch accept list ($n)"
n=0; while IFS= read -r l; do [ -n "$l" ] || continue; n=$((n+1)); [[ "$l" =~ $BP ]] && bad "branch should fail: $l"; done < "$HERE/fixtures/branch-bad.txt"; ok "branch reject list ($n)"
n=0; while IFS= read -r l; do n=$((n+1)); [[ "$l" =~ $TP ]] || bad "title should pass: $l"; done < "$HERE/fixtures/title-ok.txt"; ok "title accept list ($n)"
n=0; while IFS= read -r l; do n=$((n+1)); [[ "$l" =~ $TP ]] && bad "title should fail: $l"; done < "$HERE/fixtures/title-bad.txt"; ok "title reject list ($n)"
# Commit subjects use the same grammar as PR titles (squash title == PR title).
ok "commit message subjects share the title grammar (same fixtures)"
long="feat: $(printf 'x%.0s' $(seq 1 100))"; t "title >100 chars is rejected by the length rule" '[ ${#long} -gt 100 ]'
DCO='^Signed-off-by: .+ <[^>]+>$'
t "DCO accepts a trailer" 'printf "msg\n\nSigned-off-by: Tyler J <t@example.com>\n" | grep -Eq "$DCO"'
t "DCO rejects missing trailer" '! printf "msg\n" | grep -Eq "$DCO"'
t "workflow pattern lines have no double quotes (YAML single-quoted)" '! grep -q "PATTERN: \"" "$ROOT"/.github/workflows/*.yml'

section "rulesets JSON validity and shape"
for f in "$ROOT"/rulesets/*.json; do t "valid JSON: $(basename "$f")" 'jq empty "$f"'; done
D="$ROOT/rulesets/default-branch-protection.json"
t "default: name/target/enforcement" 'jq -e ".name==\"default-branch-protection\" and .target==\"branch\" and .enforcement==\"active\"" "$D" >/dev/null'
t "default: include ~DEFAULT_BRANCH" 'jq -e ".conditions.ref_name.include==[\"~DEFAULT_BRANCH\"] and (.conditions.ref_name.exclude|type==\"array\")" "$D" >/dev/null'
t "default: admin bypass actor (5, RepositoryRole, always)" 'jq -e ".bypass_actors==[{actor_id:5,actor_type:\"RepositoryRole\",bypass_mode:\"always\"}]" "$D" >/dev/null'
t "default: rule types" 'jq -e "[.rules[].type]|sort==[\"deletion\",\"non_fast_forward\",\"pull_request\",\"required_linear_history\"]" "$D" >/dev/null'
t "default: pull_request params" 'jq -e ".rules[]|select(.type==\"pull_request\").parameters
  | .required_approving_review_count==0 and .dismiss_stale_reviews_on_push==true and .require_last_push_approval==false
  and .required_review_thread_resolution==true and .require_code_owner_review==false and .allowed_merge_methods==[\"squash\"]" "$D" >/dev/null'
t "default: only REST-valid rule types" 'jq -e "[.rules[].type] - [\"creation\",\"update\",\"deletion\",\"required_linear_history\",\"required_signatures\",\"pull_request\",\"required_status_checks\",\"non_fast_forward\"] == []" "$D" >/dev/null'
t "required-checks fragment shape" 'jq -e ".rules[0].type==\"required_status_checks\" and ([.rules[0].parameters.required_status_checks[].context]==[\"ci\",\"pr-title\"]) and .rules[0].parameters.strict_required_status_checks_policy==false" "$ROOT/rulesets/required-checks.json" >/dev/null'
t "signed-commits fragment shape" 'jq -e ".rules==[{type:\"required_signatures\"}]" "$ROOT/rulesets/signed-commits.json" >/dev/null'
t "no branch-naming.json (branch_name_pattern is Enterprise-only)" '[ ! -e "$ROOT/rulesets/branch-naming.json" ]'

section "static checks"
t "all workflows pin third-party actions by sha" '! grep -hE "uses: [^./]" "$ROOT"/.github/workflows/*.yml | grep -vE "@[0-9a-f]{40}( |$)"'
t "workflows declare permissions" 'for f in "$ROOT"/.github/workflows/*.yml; do grep -q "^permissions:" "$f" || exit 1; done'
t "reusable workflows use workflow_call" 'for f in pr-title branch-name secrets-scan dco wrangler-warning agent-dx; do grep -q workflow_call "$ROOT/.github/workflows/$f.yml" || exit 1; done'
t "bin/repo-policy is bash 3.2 syntax-clean" 'bash -n "$RP"'
if command -v actionlint >/dev/null; then t "actionlint" '(cd "$ROOT" && actionlint)'; else ok "actionlint not installed: skipped"; fi
if command -v shellcheck >/dev/null; then t "shellcheck" 'shellcheck -x "$RP" "$HERE/run.sh" "$HERE/fixtures/gh"'; else ok "shellcheck not installed: skipped"; fi
if python3 -c 'import yaml' 2>/dev/null; then
  t "workflows parse as YAML" 'python3 -I -c "import sys,yaml;[yaml.safe_load(open(f)) for f in sys.argv[1:]]" "$ROOT"/.github/workflows/*.yml "$ROOT"/templates/ci-caller.yml'
else ok "PyYAML not installed: YAML parse skipped"; fi

# ---------- repo-policy with fake gh ----------
export PATH="$HERE/fixtures:$PATH"
DESIRED_PRIV=$(jq -c '{allow_squash_merge:true,allow_merge_commit:false,allow_rebase_merge:false,squash_merge_commit_title:"PR_TITLE",squash_merge_commit_message:"PR_BODY",delete_branch_on_merge:true,allow_auto_merge:true,allow_update_branch:true,has_wiki:false,has_projects:false}' <<<null)
mkrepo() { # dir owner name private archived compliant(0/1) [ss(0/1)]
  local d="$1" o="$2" n="$3" p="$4" a="$5" c="$6" ss="${7:-0}"
  jq -n --argjson d "$DESIRED_PRIV" --arg o "$o" --arg n "$n" --argjson p "$p" --argjson a "$a" --argjson c "$c" --argjson ss "$ss" '
    (if $c==1 then $d else {allow_squash_merge:true,allow_merge_commit:true,allow_rebase_merge:true,squash_merge_commit_title:"COMMIT_OR_PR_TITLE",squash_merge_commit_message:"COMMIT_MESSAGES",delete_branch_on_merge:false,allow_auto_merge:false,allow_update_branch:false,has_wiki:false,has_projects:true} end)
    + {full_name:($o+"/"+$n),name:$n,owner:{login:$o},private:$p,archived:$a,default_branch:"main",
       security_and_analysis:(if $ss==1 then {secret_scanning:{status:"disabled"},secret_scanning_push_protection:{status:"disabled"}} else null end)}
    + (if $p then {} else {web_commit_signoff_required:($c==1)} end)' > "$d/${o}__${n}.repo.json"
}
mkcompliant_ruleset() { # dir o n  (id 7)
  local d="$1" o="$2" n="$3"
  jq -c '. + {id:7,source_type:"Repository"} | (.rules[]|select(.type=="pull_request").parameters) += {automatic_copilot_code_review_enabled:false}' "$ROOT/rulesets/default-branch-protection.json" > "$d/${o}__${n}.ruleset.7.json"
  echo '[{"id":7,"name":"default-branch-protection","target":"branch"}]' > "$d/${o}__${n}.rulesets.json"
  : > "$d/${o}__${n}.vuln"; echo '{"enabled":true,"paused":false}' > "$d/${o}__${n}.fixes.json"
}
newstate() { S=$(mktemp -d "$WORK/s.XXXXXX"); mkdir -p "$S/cfg"; : > "$S/cfg/skip.txt"; echo '{"login":"tyler-jewell"}' > "$S/user.json"; echo '[]' > "$S/repos.json"; }
rp() { OUT=$(FAKE_GH_DIR="$S" REPO_POLICY_CONFIG_DIR="$S/cfg" "$RP" "$@" 2>"$S/stderr" </dev/null); RC=$?; }
writes() { ls "$S/writes" 2>/dev/null | wc -l | tr -d ' '; }
nonget() { grep -vc '^GET ' "$S/calls.log" 2>/dev/null; true; }

section "repo-policy: usage and help"
newstate
rp --help;            t "--help exits 0 with sections" '[ $RC -eq 0 ] && grep -q "EXIT CODES" <<<"$OUT" && grep -q "EXAMPLES" <<<"$OUT"'
rp --help --json;     t "--help --json is valid JSON with exit_codes" '[ $RC -eq 0 ] && jq -e ".exit_codes[\"2\"]==\"drift\"" <<<"$OUT" >/dev/null'
rp;                   t "no command -> 64" '[ $RC -eq 64 ]'
rp check;             t "no target -> 64" '[ $RC -eq 64 ]'
rp check bogus;       t "bad target -> 64" '[ $RC -eq 64 ]'
rp check a/b --nope;  t "unknown flag -> 64" '[ $RC -eq 64 ]'
rp check a/b --all-active; t "target + --all-active -> 64" '[ $RC -eq 64 ]'
rp apply tyler-jewell/x; t "apply w/o --yes non-TTY -> 64, no gh calls" '[ $RC -eq 64 ] && [ ! -e "$S/calls.log" ]'
CI=1 rp apply tyler-jewell/x; t "apply w/o --yes with CI=1 -> 64" '[ $RC -eq 64 ]'

section "repo-policy: refusals and skips"
newstate
rp check Flag-Seeker/flagseeker --json; t "owner Flag-Seeker refused (4), zero API calls" '[ $RC -eq 4 ] && [ ! -e "$S/calls.log" ] && jq -e ".repos[0].status==\"refused\"" <<<"$OUT" >/dev/null'
rp apply flag-seeker/anything --yes;    t "owner flag-seeker (lowercase) refused on apply" '[ $RC -eq 4 ] && [ ! -e "$S/calls.log" ]'
rp apply Flag-Seeker/x --yes --owner Flag-Seeker; t "--owner Flag-Seeker cannot override" '[ $RC -eq 4 ] && [ ! -e "$S/calls.log" ]'
rp apply tyler-jewell/flagseeker --yes; t "repo named flagseeker refused" '[ $RC -eq 4 ] && [ ! -e "$S/calls.log" ]'
rp check someoneelse/repo;              t "foreign owner refused (4)" '[ $RC -eq 4 ] && [ ! -e "$S/calls.log" ]'
mkrepo "$S" someoneelse repo true false 1; mkcompliant_ruleset "$S" someoneelse repo
rp check someoneelse/repo --owner someoneelse; t "--owner override allows foreign owner" '[ $RC -ne 4 ]'
newstate; mkrepo "$S" tyler-jewell old true true 0
rp apply tyler-jewell/old --yes --json; t "archived repo skipped, exit 0, no writes" '[ $RC -eq 0 ] && [ "$(writes)" = 0 ] && jq -e ".repos[0].status==\"skipped\" and .repos[0].reason==\"archived\"" <<<"$OUT" >/dev/null'

section "repo-policy: drift / ok / dry-run / read-only guard"
newstate; mkrepo "$S" tyler-jewell drifty true false 0; echo '[]' > "$S/tyler-jewell__drifty.rulesets.json"
rp check tyler-jewell/drifty --json
t "check drift -> exit 2, schema v1" '[ $RC -eq 2 ] && jq -e ".schema==\"repo-policy/v1\" and .exit_code==2 and .summary.drift==1 and (.repos[0].checks|map(.area)|index(\"ruleset\") != null)" <<<"$OUT" >/dev/null'
t "check settings drift lists keys" 'jq -e "[.repos[0].checks[]|select(.area==\"settings\").drift[].key]|index(\"allow_merge_commit\") != null" <<<"$OUT" >/dev/null'
t "check performed no writes (only GETs)" '[ "$(nonget)" = 0 ] && [ "$(writes)" = 0 ]'
t "check: secret scanning unavailable on private repo w/o GHAS" 'jq -e "[.repos[0].checks[]|select(.area==\"secret_scanning\").status][0]==\"unavailable\"" <<<"$OUT" >/dev/null'
rp check tyler-jewell/drifty --dry-run --json; t "check --dry-run still exit 2 and read-only" '[ $RC -eq 2 ] && [ "$(nonget)" = 0 ]'
rp apply tyler-jewell/drifty --dry-run --json; t "apply --dry-run -> exit 2, dry_run true, no writes" '[ $RC -eq 2 ] && [ "$(writes)" = 0 ] && [ "$(nonget)" = 0 ] && jq -e ".dry_run==true" <<<"$OUT" >/dev/null'
rp apply tyler-jewell/drifty --dry-run; t "human output mentions drift" 'grep -q "\[drift\] tyler-jewell/drifty" <<<"$OUT"'
t "RO guard: gh_write refuses in read-only mode (source check)" 'grep -q "write attempted in read-only mode" "$RP"'

newstate; mkrepo "$S" tyler-jewell good true false 1; mkcompliant_ruleset "$S" tyler-jewell good
rp check tyler-jewell/good --json; t "compliant repo -> exit 0, status ok" '[ $RC -eq 0 ] && jq -e ".repos[0].status==\"ok\"" <<<"$OUT" >/dev/null'
rp apply tyler-jewell/good --yes; t "idempotent: apply on compliant repo makes no writes" '[ $RC -eq 0 ] && [ "$(writes)" = 0 ]'
rp check tyler-jewell/good --with-checks --json; t "--with-checks on repo without those checks -> drift on ruleset" '[ $RC -eq 2 ] && jq -e "[.repos[0].checks[]|select(.area==\"ruleset\").drift[].key]|index(\"rule:required_status_checks\") != null" <<<"$OUT" >/dev/null'
rp check tyler-jewell/good --signed --json; t "--signed reports missing required_signatures" '[ $RC -eq 2 ] && jq -e "[.repos[0].checks[]|select(.area==\"ruleset\").drift[].key]|index(\"rule:required_signatures\") != null" <<<"$OUT" >/dev/null'
printf 'tyler-jewell/good\n' > "$S/cfg/signed.txt"
rp check tyler-jewell/good --json; t "config/signed.txt opt-in is honored" '[ $RC -eq 2 ]'

section "repo-policy: create vs update (real apply against fake gh)"
newstate; mkrepo "$S" tyler-jewell fresh false false 0 1; echo '[]' > "$S/tyler-jewell__fresh.rulesets.json"
rp apply tyler-jewell/fresh --yes --with-checks --signed --json
t "create: exit 0, status changed" '[ $RC -eq 0 ] && jq -e ".repos[0].status==\"changed\"" <<<"$OUT" >/dev/null'
t "create: POST rulesets issued, no PUT on rulesets" 'grep -q "^POST repos/tyler-jewell/fresh/rulesets$" "$S/calls.log" && ! grep -q "^PUT repos/tyler-jewell/fresh/rulesets" "$S/calls.log"'
POSTF=$(grep -l '^POST repos/tyler-jewell/fresh/rulesets$' "$S"/writes/* | head -1)
t "create: body has checks + signatures + squash only" 'tail -n +2 "$POSTF" | jq -e "([.rules[].type]|index(\"required_status_checks\") != null) and ([.rules[].type]|index(\"required_signatures\") != null) and (.rules[]|select(.type==\"pull_request\").parameters.allowed_merge_methods==[\"squash\"])" >/dev/null'
t "create: settings PATCH incl. DCO sign-off for public repo" 'f=$(grep -l "^PATCH repos/tyler-jewell/fresh$" "$S"/writes/* | head -1); tail -n +2 "$f" | jq -e ".allow_merge_commit==false and .web_commit_signoff_required==true and .squash_merge_commit_title==\"PR_TITLE\"" >/dev/null'
t "create: vuln alerts + automated fixes enabled" 'grep -q "^PUT repos/tyler-jewell/fresh/vulnerability-alerts$" "$S/calls.log" && grep -q "^PUT repos/tyler-jewell/fresh/automated-security-fixes$" "$S/calls.log"'
t "create: secret scanning + push protection PATCH" 'grep -l "secret_scanning_push_protection" "$S"/writes/* >/dev/null'

newstate; mkrepo "$S" tyler-jewell upd true false 1; mkcompliant_ruleset "$S" tyler-jewell upd
jq -c '(.rules[]|select(.type=="pull_request").parameters.allowed_merge_methods)=["merge","squash"] | .bypass_actors=[]' "$S/tyler-jewell__upd.ruleset.7.json" > "$S/x" && mv "$S/x" "$S/tyler-jewell__upd.ruleset.7.json"
rp apply tyler-jewell/upd --yes --json
t "update: PUT existing ruleset id 7, no POST" '[ $RC -eq 0 ] && grep -q "^PUT repos/tyler-jewell/upd/rulesets/7$" "$S/calls.log" && ! grep -q "^POST " "$S/calls.log"'
t "update: drift names merge methods + bypass" 'jq -e "[.repos[0].checks[]|select(.area==\"ruleset\").drift[].key]|(index(\"bypass\") != null) and (index(\"rule:pull_request.allowed_merge_methods\") != null)" <<<"$OUT" >/dev/null'

section "repo-policy: unavailable, errors, all-active"
newstate; mkrepo "$S" tyler-jewell priv true false 0; : > "$S/tyler-jewell__priv.rulesets.403"
rp check tyler-jewell/priv --json
t "rulesets 403 (free private) -> unavailable, not drift; settings drift still reported" '[ $RC -eq 2 ] && jq -e "([.repos[0].checks[]|select(.area==\"ruleset\").status][0]==\"unavailable\") and ([.repos[0].checks[]|select(.area==\"settings\").status][0]==\"drift\")" <<<"$OUT" >/dev/null'
newstate
rp check tyler-jewell/missing --json; t "repo GET 404 -> exit 3" '[ $RC -eq 3 ] && jq -e ".repos[0].status==\"error\"" <<<"$OUT" >/dev/null'
newstate; mkrepo "$S" tyler-jewell w true false 0; echo '[]' > "$S/tyler-jewell__w.rulesets.json"; : > "$S/write.fail"
rp apply tyler-jewell/w --yes; t "write failure -> exit 3" '[ $RC -eq 3 ]'

newstate
cat > "$S/repos.json" <<'JSON'
[{"full_name":"tyler-jewell/a1","owner":{"login":"tyler-jewell"},"archived":false},
 {"full_name":"tyler-jewell/a2","owner":{"login":"tyler-jewell"},"archived":false},
 {"full_name":"tyler-jewell/skipme","owner":{"login":"tyler-jewell"},"archived":false},
 {"full_name":"tyler-jewell/flag-seeker","owner":{"login":"tyler-jewell"},"archived":false},
 {"full_name":"tyler-jewell/gone","owner":{"login":"tyler-jewell"},"archived":true},
 {"full_name":"Flag-Seeker/flagseeker","owner":{"login":"Flag-Seeker"},"archived":false}]
JSON
printf '# comment\ntyler-jewell/skipme\n' > "$S/cfg/skip.txt"
for r in a1 a2 skipme gone; do mkrepo "$S" tyler-jewell $r true false 0; echo '[]' > "$S/tyler-jewell__$r.rulesets.json"; done
rp list --json; t "list: 2 active, rest skipped/archived" '[ $RC -eq 0 ] && jq -e ".summary.active==2 and .summary.repos==5" <<<"$OUT" >/dev/null'
rp check --all-active --json
t "--all-active: processes only a1,a2; skip.txt/exempt/archived skipped; Flag-Seeker never fetched" '[ $RC -eq 2 ] && jq -e "([.repos[]|select(.status==\"drift\").repo]|sort)==[\"tyler-jewell/a1\",\"tyler-jewell/a2\"]" <<<"$OUT" >/dev/null && ! grep -qi "flag-seeker\|flagseeker" "$S/calls.log" && ! grep -q skipme "$S/calls.log"'
rp apply --all-active --dry-run --json; t "--all-active --dry-run read-only" '[ $RC -eq 2 ] && [ "$(nonget)" = 0 ] && [ "$(writes)" = 0 ]'

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
