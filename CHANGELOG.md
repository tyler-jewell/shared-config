# Changelog

## Unreleased

- feat(ci): reusable `select-runner.yml` + `scripts/select-runner.sh` picker: prefer the self-hosted `mac-studio` runner, fall back to `ubuntu-latest`; fork PRs and untrusted events never use it. Docs: `docs/RUNNERS.md`; `templates/ci-caller.yml` and shared-config CI adopt it.

## 1.0.0

- Initial release: rulesets, `bin/repo-policy`, reusable workflows, templates, docs, tests.
