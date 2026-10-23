# Rulesets and repo settings

Source of truth: `rulesets/*.json` (REST body for `POST /repos/{owner}/{repo}/rulesets`) and the settings in `bin/repo-policy`.

## default-branch-protection (always)

| Rule | Effect |
|---|---|
| `pull_request` (0 approvals) | Changes reach `main` only via PR. Stale reviews dismissed on push, review threads must be resolved, only `squash` allowed. |
| `required_linear_history` | No merge commits on `main`. |
| `non_fast_forward` | Blocks force-push. |
| `deletion` | Blocks deleting `main`. |

Targets `~DEFAULT_BRANCH`, so it follows a renamed default branch. `require_last_push_approval` is false because there is a single maintainer (the last pusher is also the only reviewer).

## Why admin bypass

`bypass_actors` holds the repository admin role (`actor_id` 5, `RepositoryRole`, `always`). With one owner and no required approvals, a broken ruleset or a failing required check must never lock Tyler out. It is an emergency door, not a workflow.

## Repo settings (PATCH /repos)

Squash only; merge commits and rebase off; squash title `PR_TITLE` and message `PR_BODY` (the PR description keeps the why and `Closes #n` in history; `BLANK` would drop it); delete branch on merge; allow auto-merge; allow update branch; wiki and projects off; web commit sign-off required on public repos (DCO). Also Dependabot alerts and security updates, secret scanning and push protection where offered.

## Opt-in: required checks (`--with-checks`)

Adds `required_status_checks` with contexts `ci` and `pr-title` (strict policy off). Apply only to repos whose CI reports those exact contexts, otherwise every PR is blocked. `templates/ci-caller.yml` defines gate jobs named `ci` and `pr-title` so the contexts match (a job that calls a reusable workflow reports as `<job> / <inner job>` instead). Override: `--checks a,b` or `REPO_POLICY_CHECKS`. Per repo without flags: list it in `config/with-checks.txt`.

## Opt-in: signed commits (`--signed`)

Adds `required_signatures`. Default off because no signing is configured yet; enabling it first would reject every unsigned commit on a PR branch. To adopt: configure SSH signing (`git config gpg.format ssh`, `user.signingkey`, `commit.gpgsign true`), upload the key to GitHub as a *signing* key, then `repo-policy apply <repo> --signed --yes` or add the repo to `config/signed.txt`. Squash commits created in the web UI are signed by GitHub.

## Branch naming cannot be a ruleset here

The `branch_name_pattern` rule (and the commit-metadata rules) belong to "metadata restrictions", which GitHub documents as available only to organizations on a GitHub Enterprise plan. Personal-account repos cannot use them, so there is no `branch-naming.json`. Naming is enforced by the reusable `branch-name.yml` check (make it required via `--with-checks` plus a gate) and by local hooks from the `dotfiles` bootstrap.

## Personal account limits, and why a tool

Personal accounts have no organization rulesets and no org-level defaults, so nothing can be inherited. `repo-policy` pushes the same ruleset and settings into each repo and `check` detects drift. Further limit observed on 2026-10: **rulesets (and branch protection) on private repos require GitHub Pro**; on a free plan `GET /repos/.../rulesets` returns 403 "Upgrade to GitHub Pro or make this repository public". `repo-policy` reports that as `unavailable` (not drift) and still applies repo settings. Server-side enforcement on private repos therefore needs Pro, or the repo to be public.

## Drift detection

`repo-policy check <repo>|--all-active` compares live state to desired: ruleset (enforcement, target, ref conditions, bypass actors, rule set, and each desired rule parameter; extra live-only parameters are ignored, extra live-only rules are drift) and each setting. Exit 2 means drift. It is read-only; writes are impossible outside a real `apply` (guarded in code, covered by tests). Run it on a schedule or before releases.

## Reusable workflows from a private repo

If `shared-config` is private, callers in other repos can use its workflows only if Actions access is enabled: repo **Settings -> Actions -> General -> Access -> "Accessible from repositories owned by the user tyler-jewell"**. Or make `shared-config` public (it contains no secrets). Tag releases (`v1`) and move the tag on compatible updates.
