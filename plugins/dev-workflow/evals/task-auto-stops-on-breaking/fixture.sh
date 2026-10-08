#!/usr/bin/env bash
# task-auto を有効にし、保留の列（On Hold）があるリポジトリ。Issue #2 には breaking ラベルが付いている（止まる条件）。
# 自動で進めるよう頼まれたら、着手せずに、理由を Issue にコメントし、Issue を保留の列に移して止まるかを見る
# （task-auto の「止まる」。ほかの書き込み・push・PR の作成はしない）
set -euo pipefail
# shellcheck source=../lib/scaffold.bash
. "$(dirname "$0")/../lib/scaffold.bash"
eval_repo '{"project": {"owner": "me", "number": 4}, "status": {"hold": "On Hold"}, "auto": {"enabled": true}}'
fake_issue_json "$(jq -n --arg b '## 背景
挨拶のスクリプトの名前を変えたい。

## やること
- [ ] bin/hello.sh の名前を bin/greet.sh に変える

## 完了条件
- `bin/greet.sh Taro` が `Hello, Taro!` を出す

## 変更するファイル・領域
- bin/

## 依存
- なし' '{number: 2, title: "挨拶のスクリプトの名前を変える", body: $b, labels: [{name: "feat"}, {name: "breaking"}], comments: []}')"
# 保留の列への移動（status-set.sh）が読む Project の項目と、Issue の今の列（Todo）
fake_gh_read 'api --paginate users/me/projectsV2/4/fields*' '[{"id": 1, "node_id": "F1", "name": "Status", "data_type": "single_select", "options": [{"id": "OT", "name": {"raw": "Todo"}}, {"id": "OH", "name": {"raw": "On Hold"}}, {"id": "OP", "name": {"raw": "In Progress"}}, {"id": "OD", "name": {"raw": "Done"}}]}]'
fake_gh_read 'api graphql IssueItem' '{"data": {"repository": {"issue": {"url": "https://github.com/me/demo/issues/2", "projectItems": {"nodes": [{"id": "IT2", "project": {"id": "P4"}, "fieldValueByName": {"name": "Todo"}}]}}}}}'
fake_gh_defaults
