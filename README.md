# geerlingguy's dotfiles

My configuration. Minimalist, but helps save a few thousand keystrokes a day. I use macOS, so I can only guarantee they'll work on a Mac, but I use some of these dotfiles on various linux servers, and they seem to be pretty flexible.

You may also be interested in my [Mac Development Ansible Playbook](https://github.com/geerlingguy/mac-dev-playbook), which configures a Mac from scratch using Ansible, and incorporates the installation and updating of a set of dotfiles like this one.

## License

MIT / BSD

## Claude Code and git hooks

- `.config/git/hooks/` is the global hooks directory (`core.hooksPath` in `.gitconfig`).
  `pre-commit` scans staged changes with `betterleaks` and blocks the commit on a finding.
  Every hook then runs the repository's own `.git/hooks/<name>` if there is one, so
  per-repo hooks keep working. A repo that sets its own local `core.hooksPath` (husky)
  skips these hooks.
- `.claude/CLAUDE.md` is linked to `~/.claude/CLAUDE.md`.
- `.claude/prefs.json` holds Claude Code settings. Claude Code rewrites
  `~/.claude/settings.json` itself, so it is merged rather than linked:
  `~/work/git/claudekit/bin/claude-prefs --prefs .claude/prefs.json --apply`.

### review-bot: automatic reviews on push

In a repository with `git config review.auto true`, the global `pre-push` hook starts
`.claude/bin/review-bot` in the background for the commits being pushed; the push is not
delayed. It runs Claude Code's built-in `/code-review medium --fix` in a separate worktree
(Sonnet, `$2` budget, allowlisted tools only). If the reviewer changed anything, the
changes become one commit on branch `review/<short sha>` on top of the pushed commit, for
you to merge. A macOS notification links the report.

- Per repo test command: `git config review.testCommand "make test"`.
- Reports and logs: `~/.local/state/review-bot/`. Tests: `.claude/tests/review-bot.test.sh`.
