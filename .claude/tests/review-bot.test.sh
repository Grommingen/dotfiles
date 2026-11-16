#!/usr/bin/env bash
# Tests the global pre-push hook and review-bot on throwaway repositories with a fake
# `claude`. Needs git and betterleaks. No network, no API calls.
set -uo pipefail
here=$(cd "$(dirname "$0")/../.." && pwd)
BOT="$here/.claude/bin/review-bot"; PREPUSH="$here/.config/git/hooks/pre-push"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export REVIEW_BOT_STATE="$tmp/state" REVIEW_BOT_NOTIFY_LOG="$tmp/notify.log"
pass=0; failed=0
check() { if eval "$2"; then echo "ok   $1"; pass=$((pass+1)); else echo "FAIL $1"; failed=$((failed+1)); fi; }

# Fake reviewer. FAKE_MODE: fix (edits a.txt), clean, crash, leak (adds a token).
cat >"$tmp/claude" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$FAKE_ARGS"
git diff --cached --name-only >"$FAKE_SAW"
case "$FAKE_MODE" in
  crash) exit 1 ;;
  fix)   echo fixed >>a.txt ;;
  leak)  echo "token = \"ghp_$(LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 36)\"" >cfg.py ;;
esac
echo "REPORT: one finding in a.txt"
FAKE
chmod +x "$tmp/claude"
export REVIEW_BOT_CLAUDE="$tmp/claude" FAKE_ARGS="$tmp/args" FAKE_SAW="$tmp/saw"

new_repo() {   # two commits; review HEAD~1..HEAD
  local r="$tmp/$1"; git init -q "$r"; cd "$r"
  git config user.email t@t; git config user.name t
  echo one >a.txt; git add -A; git commit -qm one; echo two >>a.txt; git commit -qam two
  echo "$r"
}
branch_of() { echo "review/$(git -C "$1" rev-parse --short=12 HEAD)"; }

# 1. reviewer fixes something: fix commit on review/<id>, on top of HEAD
r=$(new_repo fix); b=$(branch_of "$r"); h=$(git -C "$r" rev-parse HEAD)
FAKE_MODE=fix "$BOT" "$r" HEAD~1 HEAD
check "fix: branch created"               'git -C "$r" rev-parse -q --verify "$b" >/dev/null'
check "fix: branch is HEAD + one commit"  '[ "$(git -C "$r" rev-parse "$b~1")" = "$h" ]'
check "fix: commit holds the fix"         'git -C "$r" show "$b:a.txt" | grep -qx fixed'
check "fix: report in commit message"     'git -C "$r" log -1 --format=%B "$b" | grep -q "REPORT: one finding"'
check "fix: report saved"                 'grep -q "REPORT" "$REVIEW_BOT_STATE"/reports/fix-*.md'
check "fix: reviewer saw the change as uncommitted diff" 'grep -qx a.txt "$tmp/saw"'
check "fix: own working tree untouched"   '[ "$(cat "$r/a.txt")" = "$(printf "one\ntwo")" ] && [ -z "$(git -C "$r" status --porcelain)" ]'
check "fix: worktree and lock removed"    '[ -z "$(find "$REVIEW_BOT_STATE/worktrees" "$REVIEW_BOT_STATE/locks" -mindepth 1)" ]'
check "fix: notified"                     'grep -q "Review done in fix: Fixes on $b" "$REVIEW_BOT_NOTIFY_LOG"'
check "flags: built-in /code-review --fix" 'grep -qx "/code-review medium --fix" "$tmp/args"'
check "flags: sonnet, budget 2, dontAsk"  'grep -qx sonnet "$tmp/args" && grep -qx 2 "$tmp/args" && grep -qx dontAsk "$tmp/args"'
check "flags: edits limited to worktree"  'grep -q "^Edit(//.*/worktrees/.*/\*\*)$" "$tmp/args"'
check "flags: commit and push denied"     'grep -qx "Bash(git commit\*)" "$tmp/args" && grep -qx "Bash(git push\*)" "$tmp/args"'
check "flags: no test command by default" '! grep -q "make test" "$tmp/args"'

# 2. nothing to fix: no branch
r=$(new_repo clean); git -C "$r" config review.testCommand "make test"
FAKE_MODE=clean "$BOT" "$r" HEAD~1 HEAD
check "clean: no branch"                  '[ -z "$(git -C "$r" branch --list "review/*")" ]'
check "clean: notified"                   'grep -q "Review done in clean: No fixes" "$REVIEW_BOT_NOTIFY_LOG"'
check "flags: test command allowed"       'grep -qx "Bash(make test)" "$tmp/args"'

# 3. reviewer crashes
r=$(new_repo crash)
FAKE_MODE=crash "$BOT" "$r" HEAD~1 HEAD
check "crash: no branch"                  '[ -z "$(git -C "$r" branch --list "review/*")" ]'
check "crash: notified"                   'grep -q "Review failed in crash" "$REVIEW_BOT_NOTIFY_LOG"'
check "crash: worktree and lock removed"  '[ -z "$(find "$REVIEW_BOT_STATE/worktrees" "$REVIEW_BOT_STATE/locks" -mindepth 1)" ]'

# 4. a fix that adds a secret is dropped
r=$(new_repo leak)
FAKE_MODE=leak "$BOT" "$r" HEAD~1 HEAD
check "leak: no branch"                   '[ -z "$(git -C "$r" branch --list "review/*")" ]'
check "leak: notified"                    'grep -q "Review in leak: fixes not kept" "$REVIEW_BOT_NOTIFY_LOG"'

# 5. two bots for the same HEAD: one review
r=$(new_repo race); : >"$tmp/calls"
cat >"$tmp/slow" <<SLOW
#!/usr/bin/env bash
echo run >>"$tmp/calls"; sleep 1; FAKE_MODE=clean exec "$tmp/claude" "\$@"
SLOW
chmod +x "$tmp/slow"
REVIEW_BOT_CLAUDE="$tmp/slow" "$BOT" "$r" HEAD~1 HEAD & REVIEW_BOT_CLAUDE="$tmp/slow" "$BOT" "$r" HEAD~1 HEAD & wait
check "race: reviewer ran once"           '[ "$(wc -l <"$tmp/calls" | tr -d " ")" = 1 ]'

# 6. pre-push hook
printf '#!/usr/bin/env bash\necho "$@" >>"%s"\n' "$tmp/started" >"$tmp/botstub"; chmod +x "$tmp/botstub"
export REVIEW_BOT_BIN="$tmp/botstub"
z=0000000000000000000000000000000000000000
r=$(new_repo push); cd "$r"; root=$(git rev-parse --show-toplevel)
one=$(git rev-parse HEAD~1); two=$(git rev-parse HEAD)
git update-ref refs/remotes/origin/main "$one"; git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
printf '#!/bin/sh\ncat >"%s"\nexit ${LOCAL_EXIT:-0}\n' "$tmp/local-stdin" >.git/hooks/pre-push; chmod +x .git/hooks/pre-push
push() { : >"$tmp/started"; printf '%s\n' "$1" | "$PREPUSH" origin url; rc=$?; sleep 0.5; }

push "refs/heads/main $two refs/heads/main $one"
check "pre-push: idle without review.auto" '[ ! -s "$tmp/started" ] && [ $rc = 0 ]'
git config review.auto true
push "refs/heads/main $two refs/heads/main $one"
check "pre-push: update starts bot for remote..local" 'grep -qx "$root $one $two" "$tmp/started"'
push "refs/heads/feat $two refs/heads/feat $z"
check "pre-push: new branch reviewed from origin/HEAD" 'grep -qx "$root $one $two" "$tmp/started"'
push "(delete) $z refs/heads/old $two"
check "pre-push: deletion ignored"         '[ ! -s "$tmp/started" ]'
push "refs/heads/main $two refs/heads/main $two"
check "pre-push: nothing new ignored"      '[ ! -s "$tmp/started" ]'
check "pre-push: repo hook got the same stdin" 'grep -qx "refs/heads/main $two refs/heads/main $two" "$tmp/local-stdin"'
LOCAL_EXIT=1 push "refs/heads/main $two refs/heads/main $one"
check "pre-push: repo hook can still block" '[ $rc = 1 ]'

echo "$pass passed, $failed failed"
[ "$failed" = 0 ]
