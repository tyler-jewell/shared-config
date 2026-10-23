# shared-config

One strict, common way of working for all of Tyler's repos, enforced server-side where GitHub allows it.

- `rulesets/` GitHub ruleset definitions (default branch protection; opt-in required checks and signed commits)
- `bin/repo-policy` applies/checks rulesets and repo settings across repos (bash + gh + jq)
- `.github/workflows/` reusable workflows: pr-title, branch-name, secrets-scan, dco, wrangler-warning, agent-dx (placeholder)
- `templates/` PR/issue templates, CONTRIBUTING, SECURITY, CODEOWNERS, dependabot, release-please, caller workflow
- `docs/` [WORKFLOW](docs/WORKFLOW.md), [RULESETS](docs/RULESETS.md), [EXEMPTIONS](docs/EXEMPTIONS.md); [AGENTS.md](AGENTS.md) for agents

## Use

    bin/repo-policy check tyler-jewell/mac-studio          # read-only, exit 2 on drift
    bin/repo-policy apply tyler-jewell/mac-studio --dry-run
    bin/repo-policy apply --all-active --yes
    bin/repo-policy list --json

Requires `gh` (authenticated, repo admin), `jq`, bash 3.2+. Tests: `bash tests/run.sh`.

License: Apache-2.0.
