---
# ワークツリー（.claude/worktrees/ の下）や、作業のファイル（bin/farewell.sh）を作っていないか
type: regex
target: files
pattern: '^(\.claude/worktrees/|bin/)'
flags: m
match: not_contains
---
