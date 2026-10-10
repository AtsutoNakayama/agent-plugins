---
# 止まらずに PR の作成まで進んだか（起票は PR の作成を妨げない）。起票したか・起票が PR より先かは files-issue が見る
# （同じ式にすると、起票し忘れたときに両方が落ち、止まって PR を作らなかったのかが見分けられないため）
type: regex
target: { source: file, path: .fake-gh/writes }
pattern: '^pr create( |$)'
flags: m
match: contains
---
