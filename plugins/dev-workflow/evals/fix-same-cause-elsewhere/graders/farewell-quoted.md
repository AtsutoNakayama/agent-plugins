---
# printf の行で、名前をクォートした変数で渡しているか（ファイルを消したり、printf に渡さなくなったりしたときに落とす。
# name="$1" のような代入の行では通さない）
type: regex
target: { source: file, path: bin/farewell.sh }
pattern: 'printf[^\n]*"\$\{?(name|1|\*|@)\}?"'
---
