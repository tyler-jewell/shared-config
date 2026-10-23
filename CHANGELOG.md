# Changelog

## Unreleased

- feat(ci): token-free `RUNNER_MODE` (`hosted` default, `studio`, `auto`) for the picker, read from `vars.RUNNER_MODE` or the `mode` input; fork PRs and untrusted events are always hosted. New `os` input (`macos` -> `mac-studio`, `linux` -> `mac-studio-linux`), outputs `macos`, `linux`, `mode`. `labels` now defaults to empty (derived from `os`). `bin/runner-mode` kill-switch helper. Behaviour change: with `RUNNER_MODE` unset the picker is now `hosted` (previously it called the API); set `auto` for the old behaviour.

- feat(ci): reusable `select-runner.yml` + `scripts/select-runner.sh` picker: prefer the self-hosted `mac-studio` runner, fall back to `ubuntu-latest`; fork PRs and untrusted events never use it. Docs: `docs/RUNNERS.md`; `templates/ci-caller.yml` and shared-config CI adopt it.

## 1.0.0

- Initial release: rulesets, `bin/repo-policy`, reusable workflows, templates, docs, tests.
