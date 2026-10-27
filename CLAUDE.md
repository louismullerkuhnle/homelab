# Guidelines for Claude Code

Read `README.md` first. What follows complements it.

## Repository

- Everything in English: guides, script output, comments, commits.
- Public and generic: no personal data (name, email, domain, IP, user). Machine-specific values are asked by `setting` and saved in `/etc/homelab.conf`; in the guides they are written in angle brackets: `<user>`, `<NAS_IP>`, `<public name>`.
- No secrets: entered through `ask_secret`, written as `600 root` with `printf`.
- Minimal tree: `lib.sh` at the root, then `<machine>/<name>.md` + `<machine>/<name>.sh` (`workstation`, `pve`, `vm`), no numbering. No new folder or extra file unless asked: a file installed as is gets embedded in its script.

## Git

- Straight on `main`, no branches, no history rewrite unless explicitly asked.
- One commit per topic, in the README format; body as a bullet list. Cross-cutting change: a single commit without scope.

## Guides (`.md`)

Title, one-sentence summary, Target / Requirements / Files table, *Script* section (`curl` command), numbered *Manual* section, then *Undo* and *Notes* when useful. Flag any rewrite of the manual content.

## Scripts (`.sh`)

- Header: description (line 2), `curl` commands, loading of `lib.sh` (local, otherwise GitHub), identical across scripts.
- One function per step; `main` parses the options, calls `start`, `run_steps … check`, `mark_done`, `finish`, `next_steps`, `hl_exit`.
- Everything shared goes in `lib.sh`, never copied into a script.
- One line per action (`ok`, `skip`, `warn`, `ko`, `die`, `note`); every verbose command goes through `run` or `chk`. A `$(…)` substitution that can fail ends with `|| true`.
- Idempotent: `write_if_changed` / `replace_if_changed`, services restarted only when something changed, user settings never overwritten.
- Safeguards: `add_apt_repo` with official fingerprints, no SSH hardening without a valid key, stop before any change when a requirement is missing.
- Before committing: `shellcheck -x lib.sh */*.sh` with no warning.
- Never present a script as validated: only a run on the real machine validates it.
