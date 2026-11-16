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
