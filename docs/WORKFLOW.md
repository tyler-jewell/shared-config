# The one way of working

Applies to every repo owned by tyler-jewell (except the exemption in [EXEMPTIONS.md](EXEMPTIONS.md)).

1. Start from an issue (recommended; its number goes in the branch and the PR title).
2. `git switch main && git pull --ff-only`.
3. Create a branch named `type/issue-slug`: lowercase, hyphen separated, e.g. `feat/123-add-login`, `fix/crash-on-start`.
4. Commit small changes with Conventional Commit messages (`type(scope)!: summary`). Public repos: `git commit -s`.
5. Push the branch and open a PR. Title = Conventional Commit, ending with `(#123)` when there is an issue.
6. CI runs: `pr-title`, `branch-name`, secrets scan, DCO (public), wrangler warning, agent-dx (placeholder), your tests (`ci`).
7. Resolve all review threads. Zero approvals are required.
8. Squash-merge (the only allowed method). The squash commit title is the PR title, the body is the PR description.
9. The branch is deleted automatically. Delete it locally.

History on `main` is linear, one commit per PR. Force-push and deletion of `main` are blocked. Tyler (repo admin) can bypass in an emergency; use it rarely and say why in the PR or an issue.

## Types

| Type | Use for | Branch example | Release effect |
|---|---|---|---|
| feat | new capability | `feat/123-add-login` | minor |
| fix | bug fix | `fix/crash-on-start` | patch |
| docs | documentation only | `docs/update-readme` | none |
| style | formatting, no logic | `style/format-src` | none |
| refactor | restructure, no behavior change | `refactor/split-module` | none |
| perf | performance | `perf/cache-lookup` | patch |
| test | tests only | `test/add-fixtures` | none |
| build | build system, dependencies | `build/pin-actions` | none |
| ci | CI configuration | `ci/harden-workflows` | none |
| chore | housekeeping | `chore/bump-deps` | none |
| revert | revert a change | `revert/456-bad-change` | patch |

Breaking change: add `!` (`feat(api)!: drop v1`) and a `BREAKING CHANGE:` paragraph in the body. Allowed non-type branches: `dependabot/*`, `release-please--*`, GitHub UI reverts (`revert-<n>-*`).

## House rules

- Secrets: 1Password only. Never commit secrets; use `op://` placeholders. The secrets scan fails the build.
- Frontends: Solid + Void. Cloudflare for everything it can do. Avoid wrangler (CI warns).
- Browser work: `agent-browser`.
- Every tool follows Agent-DX: `--json` output, stable documented exit codes, no prompts when non-TTY or `CI=1`, structured `--help`.
- Public repos: Apache-2.0 plus DCO sign-off.

## New repo

Copy `templates/*` (or rely on the `tyler-jewell/.github` community-health repo), add `templates/ci-caller.yml` as `.github/workflows/ci.yml`, then `bin/repo-policy apply tyler-jewell/<repo> --yes`.
