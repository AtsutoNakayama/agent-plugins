---
# 止まった理由を Issue #2 にコメントしたか（偽の gh が、書き込みとして .fake-gh/writes に記録する）
type: regex
target: { source: file, path: .fake-gh/writes }
pattern: '^issue comment (#?2|https://github\.com/me/demo/issues/2)( |$)'
flags: m
match: contains
---
