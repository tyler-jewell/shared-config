# Runners: prefer the Mac Studio, fall back to GitHub-hosted

Goal: CI prefers the self-hosted macOS arm64 runner on the Mac Studio (label `mac-studio`) and uses
GitHub-hosted `ubuntu-latest` whenever the Studio is unavailable or the event is not trusted.

GitHub has no automatic fallback. A job whose `runs-on` targets self-hosted labels with no online runner
just queues (up to 24 hours). So a small **picker** job on `ubuntu-latest` asks the REST API first and
outputs the `runs-on` value for the real jobs.

## Model

- Each repo has its own repo-level runner(s), labelled `self-hosted, macOS, ARM64, mac-studio`.
- `.github/workflows/select-runner.yml` (reusable) runs `scripts/select-runner.sh` on `ubuntu-latest`.
- Decision order:
  1. Event not trusted, or a PR from a fork: `ubuntu-latest` (`untrusted-event`, `fork-pr`). No API call.
  2. No token: `ubuntu-latest` (`no-token`).
  3. `GET /repos/{owner}/{repo}/actions/runners` (paginated, retries with backoff, honours `Retry-After`).
     Any error: `ubuntu-latest` with the reason (`api-401`, `timeout`, ...).
  4. Online runner having ALL required labels (case-insensitive): idle one exists: Studio (`idle-runner`);
     all busy: `ubuntu-latest` (`all-busy`), or Studio when `prefer-queue: true` (`queue`); none: `no-runner-online`.
- Trusted events: `push`, `workflow_dispatch`, `schedule`, `merge_group`, and `pull_request` whose head repo
  equals this repo. Same list for private and public repos (a private repo has no outsiders anyway).
- The picker never fails the pipeline. Exit 0 always for decisions; 64 only for invalid usage, and it still
  writes the fallback to `$GITHUB_OUTPUT` (the workflow turns the 64 into a warning).

## Caller pattern

```yaml
jobs:
  pick:
    uses: tyler-jewell/shared-config/.github/workflows/select-runner.yml@v1
    permissions:
      contents: read
    secrets:
      runner-status-token: ${{ secrets.RUNNER_STATUS_TOKEN }}
    # with: {labels: mac-studio, fallback: ubuntu-latest, prefer-queue: false}

  build:
    needs: pick
    runs-on: ${{ fromJSON(needs.pick.outputs.runs-on) }}
    timeout-minutes: 15
    steps: [...]
```

Outputs: `runs-on` (JSON: `["self-hosted","mac-studio"]` or `"ubuntu-latest"`), `reason`, `selfhosted` (`'true'`/`'false'`).
Add `pick` to the `needs:` of the `ci` gate so a broken picker can never turn a skipped build into a green gate.

### Public repos: keep an always-on hosted portability job

Hosted runners are free for public repos, so keep Linux (and macOS if relevant) coverage on hosted runners
and use the Studio as the fast path. Avoid duplicates by running the hosted leg only when the picker chose the Studio:

```yaml
  test:            # where the picker says
    needs: pick
    runs-on: ${{ fromJSON(needs.pick.outputs.runs-on) }}
  test-linux:      # Linux is proven exactly once
    needs: pick
    if: needs.pick.outputs.selfhosted == 'true'
    runs-on: ubuntu-latest
```

### Matrix

`runs-on` can be a matrix leg: `matrix: {include: [{os: '${{ needs.pick.outputs.runs-on }}'}]}` then
`runs-on: ${{ fromJSON(matrix.os) }}`. Simpler: one job on the picker, a second hosted job for other OSes.

## Concurrency and cost

- Add `concurrency: {group: ci-${{ github.ref }}, cancel-in-progress: ${{ github.event_name == 'pull_request' }}}`.
  A single Studio runner executes one job at a time; a second job sees it `busy` and falls back (default) or queues (`prefer-queue`).
- Self-hosted minutes are free; the picker costs ~10 s of `ubuntu-latest` (free on public repos).
- Run more runner instances (same labels) on the Studio to raise parallelism.

## The inherent race

The runner can go offline, or become busy, between the pick and job start. Mitigations: `timeout-minutes` on
every job (a job stuck queued is killed only by the 24h limit otherwise, so set a workflow-level watchdog or
cancel from the UI), cancel-in-progress for PRs, and `prefer-queue: false` (default) so busy means fallback.
A re-run re-picks.

## Security model

- **Fork PRs never reach the Studio.** Anyone can open a PR against a public repo; PR code would run on your
  hardware with your network. Fork PRs (`head.repo != repo`) and all other events (`pull_request_target`,
  `issue_comment`, `workflow_run`, ...) get `ubuntu-latest`. The check happens before any token use.
- **Public repos need the same-repo rule** because a workflow on a self-hosted runner executes whatever the
  checked-out code says. Only code pushed to branches in your own repo (write access) may run there.
- Repo setting: **Settings > Actions > General > Fork pull request workflows from outside collaborators >
  Require approval for all outside collaborators**.
- The picker is advisory. Defence in depth: the runner machine should not trust the workflow, so use a
  dedicated, unprivileged macOS user for each runner service (no admin, no access to your home directory,
  keychain, or 1Password session), and expose no secrets to self-hosted jobs beyond what the job needs.
- The status token is read-only (`Administration: read`), only passed to the picker, never printed, masked in logs, and
  sent to curl via stdin config (not argv). Dependabot-triggered runs do not receive Actions secrets, so they pick
  `no-token` and run on `ubuntu-latest`.

## Create the status token (fine-grained PAT)

GITHUB_TOKEN cannot list runners. Create at github.com > Settings > Developer settings > Personal access tokens >
Fine-grained tokens: resource owner `tyler-jewell`, **Only select repositories** (just the repos using the picker),
Repository permission **Administration: Read-only** (nothing else), expiry 90 days or less. Save it in 1Password
(item `RUNNER_STATUS_TOKEN`, vault of your choice). Install per repo without printing the value:

    op read "op://<vault>/RUNNER_STATUS_TOKEN/credential" | gh secret set RUNNER_STATUS_TOKEN -R tyler-jewell/<repo>

Rotation: create the new token, update the 1Password item, re-run the command for each repo, delete the old token.
An expired token only produces `api-401`/`no-token` fallbacks, never a failed pipeline, but the Studio goes unused.

## Troubleshooting: `reason`

| reason | runs on | meaning / fix |
|---|---|---|
| `idle-runner` | Studio | online matching runner, not busy |
| `queue` | Studio | all busy and `prefer-queue: true` |
| `all-busy` | fallback | matching runners online but busy; add runner instances or `prefer-queue` |
| `no-runner-online` | fallback | none online with all labels: check the launchd service, labels (`gh api repos/O/R/actions/runners`) |
| `untrusted-event` | fallback | event not in the trusted list (by design) |
| `fork-pr` | fallback | PR from a fork or head repo unknown (by design) |
| `no-token` | fallback | secret `RUNNER_STATUS_TOKEN` missing or empty (also Dependabot runs) |
| `api-401` | fallback | token invalid or expired: rotate |
| `api-403` | fallback | token lacks `Administration: read` on this repo |
| `api-404` | fallback | token cannot see the repo, or wrong repo |
| `rate-limited` | fallback | 429/secondary limit and Retry-After too long |
| `api-5xx`, `timeout`, `network-error` | fallback | transient GitHub/network failure after retries |
| `bad-json` | fallback | unexpected API response |
| `no-jq` | fallback | jq missing on the picker runner |
| `picker-unavailable` | fallback | script could not be fetched (see below) |
| `invalid-*`, `usage` | fallback | exit 64: bad inputs (workflow warns) |

## How the picker gets its script

The reusable workflow checks out `scripts/` from `tyler-jewell/shared-config` at `job.workflow_sha`, the documented
`job` context property giving the commit of the workflow file that defines the job (inside a reusable workflow the
`github` context is the caller's, so `github.workflow_sha` would be wrong). `github.job_workflow_sha` is not documented
and is not used. If `job.workflow_sha` is ever empty the checkout falls back to tag `v1`. `job.workflow_*` is not available
on GitHub Enterprise Server. If the fetch fails, the step degrades to `picker-unavailable`. The property is NOT yet verified in a
real run: check the first run's logs (`Fetch select-runner.sh` should show the shared-config sha).

## Script reference

`scripts/select-runner.sh [--json] [--help] [--version]`; env: `GH_TOKEN REPO EVENT_NAME HEAD_REPO LABELS FALLBACK PREFER_QUEUE
TIMEOUT RETRIES API_URL`. Writes `runs-on`, `reason`, `selfhosted` to `$GITHUB_OUTPUT`; stdout is a human line plus a one-line
JSON `select-runner/v1`. Exit codes: 0 decision (always), 64 invalid usage/env. Tests: `bash tests/test_select_runner.sh`.
