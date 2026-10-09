---
# 範囲外の指摘を起票したか。偽の gh（tests/eval/bin/fake-gh.sh）は、書き込みを引数を空白でつないだ1行で .fake-gh/writes に記録する。
# 起票は、Issue を作る REST（repos/me/demo/issues への POST）か gh issue create。REST は、メソッド（-X POST・-XPOST・
# --method POST・--method=POST）か本文（-f・-F・--field・--raw-field・--input。gh は POST で送る）が、パスの前でも後でも当たる
# （issue-create.sh は「api -X POST repos/me/demo/issues --input -」）。メソッドも本文も無い呼び出し（一覧の読み取り）と、
# repos/me/demo/issues/<番号>/… への書き込み（親子・依存など）には当たらない。
# 起票せずに PR の本文に「起票した Issue：なし」と書くと、ここで落ちる（#307）
type: regex
target: { source: file, path: .fake-gh/writes }
pattern: '^(api( .*)? /?repos/me/demo/issues( .*)? ((-X ?|--method[ =])[Pp][Oo][Ss][Tt]|-f|-F|--field|--raw-field|--input)( |=|$)|api( .*)? ((-X ?|--method[ =])[Pp][Oo][Ss][Tt]|-f|-F|--field|--raw-field|--input)( .*)? /?repos/me/demo/issues( |$)|issue create( |$))'
flags: m
match: contains
---
