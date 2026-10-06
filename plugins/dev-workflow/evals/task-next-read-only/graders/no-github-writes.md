---
# 偽の gh（tests/eval/bin/fake-gh.sh）が、GitHub に書き込む呼び出しを .fake-gh/writes に記録する。空なら書き込んでいない
type: regex
target: { source: file, path: .fake-gh/writes }
pattern: '\S'
match: not_contains
---
