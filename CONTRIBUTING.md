# Contributing

obento is one family's home server, shared so others can build their own. Fixes, clearer docs and new
modules are welcome; changes that make it harder to run one machine reliably probably aren't.

**Before you start** on anything bigger than a fix, open an issue saying what you'd like to change and why, so
we can agree on the shape first.

**Issues**: say what you ran, what you expected and what happened, with the output (`obento logs <app>`,
`journalctl -t obento`). Remove secrets first: anything from `.env`, your ntfy topic, tokens and passwords.

**Pull requests**:

- Keep them small and about one thing. New optional apps or features go in a module
  ([modules/README.md](modules/README.md)), not as `if`s in `install.sh`.
- `install.sh` must stay safe to re-run, never touch the hard drives, and change nothing for people who don't
  turn the new thing on.
- Run the checks in [AGENTS.md](AGENTS.md#verify-before-you-push): `bash -n` and `shellcheck` on changed
  scripts, `docker compose config` with and without your module, and YAML parsing.
- Update the docs in the same pull request: the README for what people get, the RUNBOOK for the steps, and the
  module table in `modules/README.md`.
- Say how you tested it, and on what hardware.

**Security problems**: please don't open a public issue. Use GitHub's private vulnerability reporting
(the repository's **Security** tab → **Report a vulnerability**).

By contributing, you agree that your contribution is licensed under the [MIT License](LICENSE).
