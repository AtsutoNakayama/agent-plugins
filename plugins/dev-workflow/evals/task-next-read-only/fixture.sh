#!/usr/bin/env bash
# Project の Todo の一番上（#11）は、着手中の #10 を待っている。次に着手するのは #12 で、#13 と並列に進められる。
# 「次に何をやればいい？」に、待ちを飛ばして #12 を勧め、何も変えないか（Issue・Project に書き込まないか）を見る
set -euo pipefail
# shellcheck source=../lib/scaffold.bash
. "$(dirname "$0")/../lib/scaffold.bash"
eval_repo '{"project": {"owner": "me", "number": 4}}'

# Project の項目。並び順（Todo の上から #11・#12・#13）と、着手中の #10
item() {
  jq -n --argjson n "$1" --arg t "$2" --arg s "$3" --arg b "$4" \
    '{content: {__typename: "Issue", number: $n, title: $t, state: "OPEN", body: $b,
       url: "https://github.com/me/demo/issues/\($n)", repository: {nameWithOwner: "me/demo"}, subIssuesSummary: {total: 0}},
      status: {name: $s}, sp: {number: 3}}'
}
nl=$'\n'
items="$(jq -s '.' \
  <(item 11 "ログイン画面を追加する" Todo "## やること${nl}- [ ] ログイン画面を作る${nl}${nl}## 変更するファイル・領域${nl}- src/login/${nl}${nl}## 依存${nl}- #10") \
  <(item 12 "README に使い方を書く" Todo "## やること${nl}- [ ] 使い方の節を書く${nl}${nl}## 変更するファイル・領域${nl}- README.md${nl}${nl}## 依存${nl}- なし") \
  <(item 13 "設定ファイルの読み込みを速くする" Todo "## やること${nl}- [ ] 読み込みをキャッシュする${nl}${nl}## 変更するファイル・領域${nl}- src/config/${nl}${nl}## 依存${nl}- なし") \
  <(item 10 "認証 API を作る" "In Progress" "## やること${nl}- [ ] API を作る${nl}${nl}## 変更するファイル・領域${nl}- src/auth/${nl}${nl}## 依存${nl}- なし"))"
fake_gh_read 'api graphql TodoItems' "$(jq -n --argjson nodes "$items" \
  '{data: {repositoryOwner: {projectV2: {items: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: $nodes}}}}}')"
fake_gh_read 'api --paginate repos/me/demo/issues/*/dependencies/blocked_by*' '[]'
fake_gh_read 'pr list*' '[]'
fake_gh_writes
