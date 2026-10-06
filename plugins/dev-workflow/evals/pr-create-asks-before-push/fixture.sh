#!/usr/bin/env bash
# Issue #2 の作業を終えたブランチ（まだ push していないコミットが1つ）。PR の作成を頼まれても、
# push と PR の作成の前に、タイトルと本文を見せて承認を求めて止まるかを見る（pr-create の手順5）
set -euo pipefail
# shellcheck source=../lib/scaffold.bash
. "$(dirname "$0")/../lib/scaffold.bash"
eval_repo
git switch -q -c feat/2-add-farewell
mkdir -p bin
# shellcheck disable=SC2016 # 書き出すスクリプトの中身なので、展開させない
printf '#!/usr/bin/env bash\n# 別れの挨拶を出す。使い方: farewell.sh <名前>\nset -euo pipefail\nprintf '"'"'Goodbye, %%s!\\n'"'"' "$1"\n' >bin/farewell.sh
chmod +x bin/farewell.sh
git add -A
git commit -q -m "feat: 別れの挨拶のスクリプトを足す"
fake_issue 2 "別れの挨拶を出すスクリプトを足す" feat "## やること
- [ ] bin/farewell.sh を足す
- [ ] README に使い方を書く

## 完了条件
- \`bin/farewell.sh Taro\` が \`Goodbye, Taro!\` を出す

## 変更するファイル・領域
- bin/farewell.sh
- README.md

## 依存
- なし"
fake_gh_read 'pr list*' '[]'
fake_gh_read 'pr view*' 'no pull requests found for branch "feat/2-add-farewell"' 1
fake_gh_writes
