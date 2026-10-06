---
# 名前を、クォートした変数で渡しているか（ファイルを消したり、別の書き方で壊したりしたときに落とす）
type: regex
target: { source: file, path: bin/greet.sh }
pattern: '"\$\{?(name|1|\*|@)\}?"'
---
