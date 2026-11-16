#!/usr/bin/env bash
# Tests review-trigger and review-bot on throwaway repositories with a fake `claude`.
# Needs git, jq, python3 with PyYAML and the review-relay plugin. No network, no API calls.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
BOT="$here/bin/review-bot"; TRIGGER="$here/hooks/review-trigger"
RELAY=${REVIEW_RELAY_BIN:-$(ls -d "$HOME"/.claude/plugins/cache/claudekit/review-relay/*/bin/review-relay | sort -V | tail -1)}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export REVIEW_BOT_STATE="$tmp/state" REVIEW_BOT_NOTIFY_LOG="$tmp/notify.log" REVIEW_RELAY_BIN="$RELAY"
pass=0; failed=0
ok()  { echo "ok   $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; failed=$((failed+1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
field() { python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1])).get(sys.argv[2], ""))' "$1" "$2"; }

# A fake reviewer. FAKE_MODE: fix (one finding, one fix commit), clean (no findings), crash.
cat >"$tmp/claude" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$FAKE_ARGS"
[ "$FAKE_MODE" = crash ] && exit 1
id=$(python3 -c 'import yaml; print(yaml.safe_load(open(".review-relay/request.yaml"))["id"])')
review-relay start --session fake >/dev/null
f=".review-relay/reviews/$id.yaml"
if [ "$FAKE_MODE" = fix ]; then
  echo fixed >>a.txt; git add a.txt; git commit -qm "fix: a" -m "Review-Relay: $id"
  sha=$(git rev-parse HEAD)
  python3 - "$f" "$sha" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
doc["findings"] = [{"id": "F1", "file": "a.txt", "summary": "s", "failure_scenario": "x",
                    "severity": "low", "outcome": "fixed", "commit": sys.argv[2]}]
yaml.safe_dump(doc, open(sys.argv[1], "w"))
PY
fi
review-relay finish >/dev/null
FAKE
chmod +x "$tmp/claude"
export REVIEW_BOT_CLAUDE="$tmp/claude" FAKE_ARGS="$tmp/args"

new_repo() {   # a repo with a pending request covering one commit
  local r="$tmp/$1"; git init -q "$r"; cd "$r"
  git config user.email t@t; git config user.name t
  echo .review-relay/ >.gitignore; echo one >a.txt; git add -A; git commit -qm one
  echo two >>a.txt; git commit -qam two
  "$RELAY" request --base HEAD~1 --head HEAD >/dev/null
  echo "$r"
}

# 1. findings with a fix: branch kept, request closed in the repo, findings copied
r=$(new_repo fix); id=$(field "$r/.review-relay/request.yaml" id)
FAKE_MODE=fix "$BOT" "$r"
check "fix: request done in repo"      '[ "$(field "$r/.review-relay/request.yaml" status)" = done ]'
check "fix: findings copied"           '[ -f "$r/.review-relay/reviews/$id.yaml" ]'
check "fix: review branch kept"        'git -C "$r" rev-parse -q --verify "review/$id" >/dev/null'
check "fix: worktree removed"          '[ -z "$(ls "$REVIEW_BOT_STATE/worktrees")" ]'
check "fix: own working tree untouched" '[ "$(cat "$r/a.txt")" = "$(printf "one\ntwo")" ]'
check "fix: notified"                  'grep -q "1 findings, 1 fix commits. Merge review/$id" "$REVIEW_BOT_NOTIFY_LOG"'
check "flags: sonnet, budget, dontAsk" 'grep -qx sonnet "$FAKE_ARGS" && grep -qx dontAsk "$FAKE_ARGS" && grep -qx 2 "$FAKE_ARGS"'
check "flags: edits limited to worktree" 'grep -q "^Edit(//.*worktrees/.*/\*\*)$" "$FAKE_ARGS"'
check "flags: no test command by default" '! grep -q "make test" "$FAKE_ARGS"'

# 2. no findings: branch deleted
r=$(new_repo clean); id=$(field "$r/.review-relay/request.yaml" id)
git -C "$r" config review.testCommand "make test"
FAKE_MODE=clean "$BOT" "$r"
check "clean: request done"            '[ "$(field "$r/.review-relay/request.yaml" status)" = done ]'
check "clean: branch deleted"          '! git -C "$r" rev-parse -q --verify "review/$id" >/dev/null'
check "clean: notified no findings"    'grep -q "Review done in clean: No findings." "$REVIEW_BOT_NOTIFY_LOG"'
check "flags: test command allowed"    'grep -qx "Bash(make test)" "$FAKE_ARGS"'

# 3. reviewer crashes: request abandoned, worktree and branch gone
r=$(new_repo crash); id=$(field "$r/.review-relay/request.yaml" id)
FAKE_MODE=crash "$BOT" "$r"
check "crash: request abandoned"       '[ "$(field "$r/.review-relay/request.yaml" status)" = abandoned ]'
check "crash: branch deleted"          '! git -C "$r" rev-parse -q --verify "review/$id" >/dev/null'
check "crash: notified"                'grep -q "Review failed in crash" "$REVIEW_BOT_NOTIFY_LOG"'

# 4. not pending: nothing happens
: >"$FAKE_ARGS"; FAKE_MODE=fix "$BOT" "$r"
check "not pending: reviewer not run"  '[ ! -s "$FAKE_ARGS" ]'

# 5. two bots at once: one review
r=$(new_repo race); : >"$tmp/calls"
cat >"$tmp/slow" <<SLOW
#!/usr/bin/env bash
echo run >>"$tmp/calls"; sleep 1; FAKE_MODE=clean exec "$tmp/claude" "\$@"
SLOW
chmod +x "$tmp/slow"
REVIEW_BOT_CLAUDE="$tmp/slow" "$BOT" "$r" & REVIEW_BOT_CLAUDE="$tmp/slow" "$BOT" "$r" & wait
check "race: reviewer ran once"        '[ "$(wc -l <"$tmp/calls" | tr -d " ")" = 1 ]'

# 6. trigger: starts the bot for a repo with a marker, never inside the reviewer
cat >"$tmp/botstub" <<STUB
#!/usr/bin/env bash
echo "\$1" >>"$tmp/trig"
STUB
chmod +x "$tmp/botstub"; : >"$tmp/trig"
r=$(new_repo trigrepo)
echo "{\"cwd\": \"$r/\"}" | REVIEW_BOT_BIN="$tmp/botstub" CLAUDE_PROJECT_DIR= "$TRIGGER"; sleep 0.5
check "trigger: bot started for repo"  'grep -qx "$(git -C "$r" rev-parse --show-toplevel)" "$tmp/trig"'
: >"$tmp/trig"
echo "{\"cwd\": \"$r\"}" | REVIEW_BOT=1 REVIEW_BOT_BIN="$tmp/botstub" "$TRIGGER"; sleep 0.5
check "trigger: idle in reviewer"      '[ ! -s "$tmp/trig" ]'
echo "{\"cwd\": \"$tmp\"}" | REVIEW_BOT_BIN="$tmp/botstub" CLAUDE_PROJECT_DIR= "$TRIGGER"; rc=$?; sleep 0.5
check "trigger: idle outside a repo"   '[ $rc = 0 ] && [ ! -s "$tmp/trig" ]'

echo "$pass passed, $failed failed"
[ "$failed" = 0 ]
