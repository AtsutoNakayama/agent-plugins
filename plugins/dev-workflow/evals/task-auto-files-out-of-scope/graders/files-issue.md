---
# 範囲外の指摘を起票したか（偽の gh が、書き込みを引数を空白でつないだ1行で .fake-gh/writes に記録する）。
# task-auto の手順5は issue-create.sh で起票すると決めているので、手順どおりに issue-create.sh で起票したかを見る。
# 数えるのは、issue-create.sh が出す形（scaffold.bash の fake_gh_defaults が #99 を返す偽の応答「api -X POST repos/me/demo/issues --input*」と
# 同じ形）と gh issue create だけにする。gh api のほかの書き方（メソッドや本文の位置など）は解釈しない（書き込みかどうかの判定は
# fake-gh.sh にあり、ここで作り直すと、読み取りや別の書き込みに当たったり、偽の応答と食い違って #99 が返らなかったりするため）。
# 起票せずに PR の本文に「起票した Issue：なし」と書くと、ここで落ちる（#307）
type: regex
target: { source: file, path: .fake-gh/writes }
pattern: '^(api -X POST repos/me/demo/issues --input( |$)|issue create( |$))'
flags: m
match: contains
---
