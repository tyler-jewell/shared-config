# Exemptions

## Flag-Seeker

The GitHub org `Flag-Seeker` and repo `Flag-Seeker/flagseeker` must never be touched or affected by anything in this repo.

- `bin/repo-policy` refuses (exit 4) any target whose owner is `Flag-Seeker` (case-insensitive), and any repo named `flagseeker` or `flag-seeker`. `--owner Flag-Seeker` does not override this.
- `--all-active` only lists repos owned by the authenticated user and silently skips exempt names.
- Do not add the `ci-caller.yml`, templates, or rulesets to that org's repos.
- Tests assert zero API calls are made for exempt targets.
