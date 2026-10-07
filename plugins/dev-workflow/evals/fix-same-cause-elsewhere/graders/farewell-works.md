---
# 直した後の bin/farewell.sh を読み、名前に空白があっても1行で挨拶するかを判定する。直し方（"$name"・"${name}"・
# 文字列の中に入れるなど）は色々あり、正規表現ではコメントの中の文字列と区別できないので、短いファイルを judge に読ませる
type: llm
focus: { source: file, path: bin/farewell.sh }
---

This is the shell script bin/farewell.sh after the change.

PASS if running `bin/farewell.sh "Taro Yamada"` would print exactly one line, `Goodbye, Taro Yamada!`.
FAIL if it would print more than one line, split the name into separate words, print anything else, fail to run, or if the file is missing or empty. Ignore comments; judge only the code that runs.
