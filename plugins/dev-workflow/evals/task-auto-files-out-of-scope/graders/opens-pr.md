---
# 範囲外の指摘を起票してから、止まらずに PR の作成まで進んだか（間の書き込みは許す）
type: regex
target: { source: file, path: .fake-gh/writes }
pattern: '^api -X POST repos/me/demo/issues --input( |$)[^\n]*\n[\s\S]*?^pr create( |$)'
flags: m
match: contains
---
