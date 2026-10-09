---
# 止まらずに PR の作成まで進んだか（起票は PR の作成を妨げない）
type: regex
target: { source: file, path: .fake-gh/writes }
pattern: '^pr create( |$)'
flags: m
match: contains
---
