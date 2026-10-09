---
# 範囲外の指摘を起票したか（issue-create.sh の REST の起票か、gh issue create。偽の gh が .fake-gh/writes に記録する）。
# 起票せずに PR の本文に「起票した Issue：なし」と書くと、ここで落ちる（#307）
type: regex
target: { source: file, path: .fake-gh/writes }
pattern: '^(api -X POST repos/me/demo/issues( |$)|issue create( |$))'
flags: m
match: contains
---
