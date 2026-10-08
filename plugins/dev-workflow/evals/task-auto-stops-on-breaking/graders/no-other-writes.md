---
# コメントと列の移動のほかに、GitHub に書き込んでいないか（割り当て・PR の作成・起票・Issue を閉じる、など）
type: regex
target: { source: file, path: .fake-gh/writes }
pattern: '^(issue (edit|create|close)|pr |api -X POST)'
flags: m
match: not_contains
---
