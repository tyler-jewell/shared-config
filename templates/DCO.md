# Developer Certificate of Origin

Public repos here are Apache-2.0 and require a DCO sign-off on every commit:

    git commit -s -m "feat(scope): summary"

This adds `Signed-off-by: Your Name <you@example.com>`, certifying you wrote the change or have the right to submit it
under the project license (full text: https://developercertificate.org/).

Forgot? Fix a branch with: `git rebase --signoff origin/main` then `git push --force-with-lease`.
Bots (Dependabot, release-please) are exempt. The check only runs on public repos.
