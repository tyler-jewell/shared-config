# Contributing

One workflow, every repo. Full detail: [shared-config docs/WORKFLOW.md](https://github.com/tyler-jewell/shared-config/blob/main/docs/WORKFLOW.md).

1. Open or pick an issue.
2. Branch from `main`: `type/issue-slug`, e.g. `feat/123-add-login`. Types: feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert.
3. Commit using Conventional Commits (`feat(auth): add login`). Public repos: sign off each commit with `git commit -s` (see [DCO.md](DCO.md)).
4. Open a PR. The title must be a Conventional Commit, e.g. `feat(auth): add login (#123)`; it becomes the squash commit title.
5. Wait for checks, resolve review threads, then squash-merge. The branch is deleted automatically.

`main` is protected: PRs only, squash-merge only, linear history, no force-push, no deletion.

## Local setup

Clone and run the bootstrap in the `dotfiles` repo (`tyler-jewell/dotfiles`); it installs the git hooks and config
(commit-msg Conventional Commit check, sign-off). Never commit secrets: use 1Password `op://` references.

## License

Public repos are Apache-2.0. By contributing you certify the [Developer Certificate of Origin](DCO.md).
