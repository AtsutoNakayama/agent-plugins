#!/usr/bin/env bash
# fix の Issue #1 は greet.sh の不具合（名前に空白があると、単語ごとに別の行になる）だけを書いている。
# 同じ原因（変数をクォートしていない）の不具合が farewell.sh にもある。両方とも直すかを見る（タスクの進め方の fix の決まり）
# 作業する場所をリポジトリのルートに固定するため、ブランチ名を {type}/{issue_number} にして、作業のブランチ fix/1 を
# ルートで切っておく。Claude が task-start でどんな短い説明を付けても、同じブランチになり、ルートを使い回す
# （別のワークツリーで直すと、ルートのファイルを見る grader で採点できない）
set -euo pipefail
# shellcheck source=../lib/scaffold.bash
. "$(dirname "$0")/../lib/scaffold.bash"
eval_repo '{"branch": {"pattern": "{type}/{issue_number}"}}'
mkdir -p bin
# shellcheck disable=SC2016 # 書き出すスクリプトの中身なので、展開させない
printf '#!/usr/bin/env bash\n# 挨拶を出す。使い方: greet.sh <名前>\nset -euo pipefail\nname=$1\nprintf '"'"'Hello, %%s!\\n'"'"' $name\n' >bin/greet.sh
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\n# 別れの挨拶を出す。使い方: farewell.sh <名前>\nset -euo pipefail\nname=$1\nprintf '"'"'Goodbye, %%s!\\n'"'"' $name\n' >bin/farewell.sh
chmod +x bin/*.sh
git add -A
git commit -q -m "feat: 挨拶のスクリプトを足す"
git push -q origin main
git switch -q -c fix/1
fake_issue 1 "名前に空白があると greet.sh の挨拶が崩れる" fix "## 背景
\`bin/greet.sh \"Taro Yamada\"\` を実行すると、\`Hello, Taro Yamada!\` ではなく、次のように2行になる。

\`\`\`
Hello, Taro!
Hello, Yamada!
\`\`\`

## やること
- [ ] 名前に空白があっても1行で挨拶するように直す

## 完了条件
- \`bin/greet.sh \"Taro Yamada\"\` が \`Hello, Taro Yamada!\` を出す

## 変更するファイル・領域
- bin/greet.sh

## 依存
- なし"
fake_gh_read 'pr list*' '[]'
fake_gh_writes
