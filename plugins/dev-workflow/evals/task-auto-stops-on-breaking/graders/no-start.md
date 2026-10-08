---
# 着手していないか（ワークツリー・作業のファイルを作っていない、push していない）
type: regex
target: files
pattern: '^(\.claude/worktrees/|bin/|\.fake-remote\.git/)'
flags: m
match: not_contains
---
