#!/usr/bin/env bash
# task-auto を有効にしていない（auto.enabled が既定の false の）リポジトリ。保留の列はある。
# Issue #2 を自動で進めるよう頼まれても、着手も書き込みもせず、有効にしていないことを伝えて止まるかを見る（task-auto の手順1）
set -euo pipefail
# shellcheck source=../lib/scaffold.bash
. "$(dirname "$0")/../lib/scaffold.bash"
eval_repo '{"project": {"owner": "me", "number": 4}, "status": {"hold": "On Hold"}}'
fake_issue 2 "別れの挨拶を出すスクリプトを足す" feat "## やること
- [ ] bin/farewell.sh を足す

## 完了条件
- \`bin/farewell.sh Taro\` が \`Goodbye, Taro!\` を出す

## 変更するファイル・領域
- bin/farewell.sh

## 依存
- なし"
fake_gh_defaults
