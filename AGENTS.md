# AGENTS.md: command contract

Tool: `bin/repo-policy <apply|check|list> [<owner/repo>|--all-active] [flags]`. Non-interactive: never prompts without a TTY or when `CI` is set; `apply` then requires `--yes` or `--dry-run`.

Flags: `--dry-run --json --with-checks --checks CSV --signed --yes --owner OWNER --help [--json] --version`.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | ok, no drift, or changes applied |
| 2 | drift (check, or apply --dry-run with pending changes) |
| 3 | API, auth, or dependency error |
| 4 | refused: owner Flag-Seeker, or owner not allowed |
| 64 | usage error |

Precedence when mixed: 3, then 4, then 2.

## JSON schema `repo-policy/v1` (stdout with `--json`)

    {
      "schema": "repo-policy/v1",
      "command": "check|apply|list",
      "dry_run": false,
      "exit_code": 0,
      "summary": {"repos": 1, "ok": 0, "drift": 1, "skipped": 0, "refused": 0, "errors": 0},
      "repos": [{
        "repo": "owner/name",
        "status": "ok|changed|drift|skipped|refused|error",
        "reason": null,
        "checks": [{
          "area": "settings|ruleset|vulnerability_alerts|automated_security_fixes|secret_scanning|secret_push_protection|repo",
          "status": "ok|drift|applied|unavailable|error",
          "action": "none|patch|create|update|enable",
          "applied": false,
          "drift": [{"key": "allow_merge_commit", "desired": false, "live": true}],
          "message": null
        }]
      }]
    }

`list --json`: `{schema, command:"list", exit_code, summary:{repos,active}, repos:[{repo,status:"active|archived|skipped",reason}]}`.

`unavailable` means GitHub does not offer the feature for that repo (for example rulesets on a private repo without Pro); it is not drift.

## Rules for agents

- Never target `Flag-Seeker`; the tool refuses.
- Run `check --json` first; `apply --dry-run --json` before `apply --yes`.
- Secrets: never commit; use 1Password `op://` references. Tests: `bash tests/run.sh`.
