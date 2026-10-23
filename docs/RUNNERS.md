# Runners: the Mac Studio with a kill switch, hosted by default

CI can run on the self-hosted macOS arm64 Mac Studio (label `mac-studio`) or on GitHub-hosted `ubuntu-latest`.
The choice is a plain repository variable, `RUNNER_MODE`. No token, no long-lived key.

GitHub has no automatic fallback: a job whose `runs-on` targets self-hosted labels with no online runner just
**queues (up to 24 hours)**. So a small **picker** job on `ubuntu-latest` decides `runs-on` first.

## Modes (`vars.RUNNER_MODE`)

| mode | behaviour |
|---|---|
| `hosted` (default when unset) | always `ubuntu-latest`. Nothing ever touches the Studio. |
| `studio` | trusted events use the Studio labels, no API call, no token. If the Studio is down, jobs queue. |
| `auto` | the picker asks the REST API for an online, idle runner and falls back to `ubuntu-latest` otherwise. Needs the OPTIONAL secret `runner-status-token` (fine-grained PAT, Administration: read). Without it: `no-token` fallback. Not recommended (long-lived key). |

**In every mode, fork PRs and untrusted events always use `ubuntu-latest`.**

Trusted events: `push`, `workflow_dispatch`, `schedule`, `merge_group`, and `pull_request` whose head repo equals this repo.
Everything else (`pull_request_target`, `issue_comment`, `workflow_run`, forks, ...) is hosted.

Fallback is always Linux (`ubuntu-latest`).

## OS labels

| `os` input | self-hosted runs-on | fallback |
|---|---|---|
| `macos` (default) | `["self-hosted","mac-studio"]` | `ubuntu-latest` |
| `linux` | `["self-hosted","mac-studio-linux"]` (the Lima VM runner) | `ubuntu-latest` |

`labels` overrides the labels of the chosen `os` (comma list; `self-hosted` is prepended). Outputs: `runs-on`, `reason`,
`selfhosted` (for the chosen `os`), plus `macos` and `linux` (runs-on JSON for each OS) and `mode`.

## Caller pattern

```yaml
jobs:
  pick:
    uses: tyler-jewell/shared-config/.github/workflows/select-runner.yml@v1
    permissions:
      contents: read
    with:
      mode: ${{ vars.RUNNER_MODE }}      # optional: the workflow also reads vars.RUNNER_MODE itself

  build:
    needs: pick
    runs-on: ${{ fromJSON(needs.pick.outputs.runs-on) }}
    timeout-minutes: 15
```

One pick job can serve a matrix over both Studio runners:

```yaml
  test:
    needs: pick
    strategy:
      matrix:
        runner: [macos, linux]
    runs-on: ${{ fromJSON(matrix.runner == 'macos' && needs.pick.outputs.macos || needs.pick.outputs.linux) }}
```

Add `pick` to the `needs:` of the `ci` gate so a broken picker can never turn a skipped build into a green gate.

### How `vars` reaches the called workflow

The docs say the `github` context in a called workflow is the caller's, and that variables are referenced with the
`vars` context, but they do not state outright that a called workflow's `vars` is the caller's. So the plumbing is
belt and braces: the workflow uses `inputs.mode || vars.RUNNER_MODE || 'hosted'`, and callers pass
`mode: ${{ vars.RUNNER_MODE }}` explicitly (certain to work, it is evaluated in the caller). If neither resolves the mode
is `hosted`, the safe direction. A caller that does not pass `mode` therefore relies on `vars` inheritance; verify it on the
first run (`reason` is `mode-studio` when working).

### Public repos: keep an always-on hosted job

Hosted runners are free for public repos; keep Linux (and macOS if relevant) proven on hosted runners:

```yaml
  test-linux:        # always hosted
    runs-on: ubuntu-latest
  test:              # Studio when RUNNER_MODE=studio, else hosted
    needs: pick
    runs-on: ${{ fromJSON(needs.pick.outputs.runs-on) }}
```

Or run the hosted leg only when the picker chose the Studio: `if: needs.pick.outputs.selfhosted == 'true'`.

## Kill switch: `bin/runner-mode`

    bin/runner-mode set hosted tyler-jewell/<repo>          # one repo, hosted
    bin/runner-mode set hosted --all-active                 # every active repo
    bin/runner-mode set studio tyler-jewell/<repo> --dry-run --json
    bin/runner-mode get tyler-jewell/<repo>
    bin/runner-mode list --all-active --json                # table of current modes

It is `gh variable set RUNNER_MODE --body hosted -R OWNER/REPO` with guard rails: `--json` (`runner-mode/v1`), `--dry-run`,
repos from `config/skip.txt` and archived repos skipped, Flag-Seeker refused. Exit codes: 0 ok, 3 gh/API error,
4 refused, 64 usage. No prompts. Org-level variable? A repo variable overrides it; the helper manages repo variables.

### When the Studio is down in `studio` mode

New jobs **queue** (up to 24h) and the PR looks stuck; there is no token to detect this, that is the accepted trade-off of
having no long-lived key. You get the ntfy alert for the Studio being down. The one-line flip:

    bin/runner-mode set hosted --all-active

then re-run the stuck workflow runs (cancel the queued ones; a re-run re-picks). Flip back to `studio` when it is healthy.
Mitigations: `timeout-minutes` on jobs does not cover queue time, so cancel stuck runs; PR concurrency
(`cancel-in-progress`) stops stale ones piling up.

## Concurrency and cost

- `concurrency: {group: ci-${{ github.ref }}, cancel-in-progress: ${{ github.event_name == 'pull_request' }}}`.
- A single runner runs one job at a time; jobs queue behind each other in `studio` mode. Run more runner instances.
- Self-hosted minutes are free; the picker costs ~10 s of `ubuntu-latest`.

## Security model

- **Fork PRs never reach the Studio.** PR code would run on your hardware and network. Fork PRs (`head.repo != repo`),
  and every other non-trusted event, get `ubuntu-latest` in every mode, before any API/token logic.
- **Public repos need the same-repo rule**: only code pushed to branches in your own repo (write access) may run there.
- Repo setting: **Settings > Actions > General > Fork pull request workflows from outside collaborators >
  Require approval for all outside collaborators**.
- Run each runner as a dedicated unprivileged macOS user (no admin, no access to your home, keychain or 1Password session);
  the Linux runner lives in the Lima VM. Expose no secrets to self-hosted jobs beyond what the job needs.
- Dependabot-triggered runs get no Actions secrets, which is fine: `hosted` and `studio` use none.
- Modes `hosted` and `studio` use no secret at all. Only `auto` can use the optional status PAT, which is read-only and masked.

## Mode `auto` (optional): the status token

GITHUB_TOKEN cannot list runners. If you ever want `auto`: fine-grained PAT, resource owner `tyler-jewell`, selected repos only,
**Administration: Read-only**, short expiry, stored in 1Password; install without printing:

    op read "op://<vault>/RUNNER_STATUS_TOKEN/credential" | gh secret set RUNNER_STATUS_TOKEN -R tyler-jewell/<repo>

and pass `secrets: {runner-status-token: ${{ secrets.RUNNER_STATUS_TOKEN }}}` to the picker. Expired token => `api-401` fallback.

## Troubleshooting: `reason`

| reason | runs on | meaning / fix |
|---|---|---|
| `mode-studio` | Studio | RUNNER_MODE=studio and the event is trusted |
| `mode-hosted` | hosted | RUNNER_MODE hosted or unset (check `get`; also shown when vars did not reach the workflow) |
| `untrusted-event` / `fork-pr` | hosted | by design, every mode |
| `idle-runner` / `queue` | Studio | auto: online idle runner / all busy with `prefer-queue` |
| `all-busy` / `no-runner-online` | hosted | auto: busy / none online with all labels |
| `no-token` | hosted | auto without the optional secret |
| `api-401` `api-403` `api-404` | hosted | auto: token invalid / lacks Administration: read / cannot see repo |
| `rate-limited` `api-5xx` `timeout` `network-error` `bad-json` | hosted | auto: API trouble after retries |
| `no-jq` | hosted | jq missing on the picker runner |
| `picker-unavailable` | hosted | script could not be fetched (see below); mode reported as hosted |
| `invalid-*`, `usage` | hosted | exit 64, bad inputs (workflow warns); e.g. `invalid-mode` for a typo in RUNNER_MODE |

## How the picker gets its script

The reusable workflow checks out `scripts/` from `tyler-jewell/shared-config` at `job.workflow_sha` (the documented
`job` context property: commit of the workflow file that defines the job; the `github` context there is the caller's),
falling back to tag `v1` if empty; `job.workflow_*` is not available on GHES. If the fetch fails the picker degrades to
`picker-unavailable` (hosted). Not verified in a real run: check the `Fetch select-runner.sh` step on the first run.

## Script reference

`scripts/select-runner.sh [--json] [--help] [--version]`; env: `MODE OS_TARGET GH_TOKEN REPO EVENT_NAME HEAD_REPO LABELS FALLBACK
PREFER_QUEUE TIMEOUT RETRIES API_URL`. Writes `runs-on`, `reason`, `selfhosted`, `macos`, `linux`, `mode` to `$GITHUB_OUTPUT`; stdout is a
human line plus a one-line JSON `select-runner/v1`. Exit codes: 0 decision (always), 64 invalid usage/env.
Tests: `bash tests/test_select_runner.sh`, `bash tests/test_runner_mode.sh`.
