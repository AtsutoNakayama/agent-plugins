#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper
load fake_gh

# gh issue view が返す Issue。使い方: cancel_issue <番号> [状態（既定 OPEN）] [stateReason] [最後のコメント]
cancel_issue() {
  jq -n --argjson n "$1" --arg s "${2:-OPEN}" --arg r "${3:-}" --arg c "${4:-}" '{
    url: "https://github.com/me/demo/issues/\($n)", number: $n, title: "作業 \($n)", state: $s, stateReason: $r,
    comments: (if $c == "" then [] else [{body: "前のコメント"}, {body: $c}] end)}' >"$FIX/issue-$1.json"
}

# やめた作業のブランチ feat/17-x の開いている PR。使い方: cancel_prs <PR ごとの最後のコメントの配列（"" ならコメント無し）>
cancel_prs() {
  jq -n --argjson c "$1" '$c | to_entries | map({number: (.key + 42), title: "PR \(.key + 42)",
    url: "https://github.com/me/demo/pull/\(.key + 42)", comments: (if .value == "" then [] else [{body: .value}] end)})' \
    >"$FIX/pr-list.json"
}

setup_cancel() {
  setup_fake_gh
  cancel_issue 17
  cancel_issue 20
}

# 呼んだ操作の順番（GitHub に書き込むものだけ）
writes() { grep -oE '^(issue-comment|issue-close|pr-comment|pr-close|api-delete) [^ ]+' "$CALLS" | tr '\n' ',' ; }

@test "理由をコメントして not planned で閉じる" {
  setup_cancel
  run_script issue-cancel.sh --issue 17 --reason "#20 で作業するため閉じます"
  assert_success
  assert_equal "$(cat "$TMP/issue-comment-body")" "#20 で作業するため閉じます"
  assert_equal "$(grep '^issue-close ' "$CALLS")" "issue-close 17 --reason not planned"
  # コメントしてから閉じる
  assert_equal "$(writes)" "issue-comment 17,issue-close 17,"
  assert_equal "$(jq -c '[.issue, .title, .dry_run, .state_reason, .duplicate_of, .comment, .commented, .closed]' <<<"$output")" \
    '[17,"作業 17",false,"NOT_PLANNED",null,"#20 で作業するため閉じます",true,true]'
}

@test "複数行の理由もそのままコメントする" {
  setup_cancel
  run_script issue-cancel.sh --issue 17 --reason "$(printf '誤って起票しました。\n\n代わりに #20 で作業します。')"
  assert_success
  assert_equal "$(cat "$TMP/issue-comment-body")" "$(printf '誤って起票しました。\n\n代わりに #20 で作業します。')"
}

@test "--duplicate-of を付けると、元の Issue に紐付けて duplicate で閉じる" {
  setup_cancel
  run_script issue-cancel.sh --issue 17 --reason "#20 と同じ内容なので閉じます" --duplicate-of 20
  assert_success
  assert_equal "$(grep '^issue-close ' "$CALLS")" "issue-close 17 --duplicate-of 20"
  assert_equal "$(jq -c '[.state_reason, .duplicate_of]' <<<"$output")" '["DUPLICATE",20]'
  assert_equal "$(jq -r '.actions[1]' <<<"$output")" \
    "Issue #17 を #20 の重複（duplicate）として閉じる（Project と Story Point はそのまま残す）"
}

@test "--duplicate-of の番号は # を付けてもよい" {
  setup_cancel
  run_script issue-cancel.sh --issue 17 --reason "重複です" --duplicate-of '#20'
  assert_success
  assert_equal "$(jq -r .duplicate_of <<<"$output")" 20
}

@test "--duplicate-of は gh が古ければ、更新を促して何もせずに止まる" {
  setup_cancel
  FAKE_GH_VERSION=2.87.0 run_script issue-cancel.sh --issue 17 --reason "重複です" --duplicate-of 20
  assert_failure 2
  assert_output --partial "重複として閉じる（gh issue close --duplicate-of）には gh 2.88.0 以上が要ります（今は 2.87.0）。gh を更新してください"
  assert_equal "$(writes)" ""
}

@test "not planned で閉じるだけなら、古い gh でも動く" {
  setup_cancel
  FAKE_GH_VERSION=2.40.0 run_script issue-cancel.sh --issue 17 --reason "やらないことにしました"
  assert_success
}

@test "重複の元の Issue が無い、または PR なら、何もせずに止まる" {
  setup_cancel
  run_script issue-cancel.sh --issue 17 --reason "重複です" --duplicate-of 99
  assert_failure 2
  assert_output --partial "重複の元の Issue #99 が me/demo にありません"
  echo '{"url": "https://github.com/me/demo/pull/21", "number": 21}' >"$FIX/issue-21.json"
  run_script issue-cancel.sh --issue 17 --reason "重複です" --duplicate-of 21
  assert_failure 2
  assert_output --partial "#21 は PR です。Issue の番号を指定してください"
  assert_equal "$(writes)" ""
}

@test "--duplicate-of に自分自身は指定できない" {
  setup_cancel
  run_script issue-cancel.sh --issue 17 --reason "重複です" --duplicate-of 017
  assert_failure 64
  assert_output --partial "--duplicate-of に閉じる Issue 自身（#17）は指定できません"
  run_script issue-cancel.sh --issue 17 --reason "重複です" --duplicate-of abc
  assert_failure 64
  assert_output --partial "--duplicate-of には数字を指定してください: abc"
}

@test "Project と Story Point には触れない" {
  setup_cancel
  run_script issue-cancel.sh --issue 17 --reason "やらないことにしました"
  assert_success
  # Project の操作（GraphQL）もラベルなどの変更（issue edit）も呼ばない
  assert_equal "$(grep -vEc '^(issue-comment|issue-close) ' "$CALLS")" 0
}

@test "理由が無い・空白だけなら閉じずに止まる" {
  setup_cancel
  run_script issue-cancel.sh --issue 17
  assert_failure 64
  assert_output --partial "--reason に閉じる理由を書いてください"
  run_script issue-cancel.sh --issue 17 --reason ""
  assert_failure 64
  run_script issue-cancel.sh --issue 17 --reason "$(printf ' \n\t ')"
  assert_failure 64
  assert_output --partial "--reason に閉じる理由を書いてください"
  # 全角スペース（日本語の入力でよく入る）だけでも止まる
  run_script issue-cancel.sh --issue 17 --reason "$(printf '\343\200\200 \343\200\200')"
  assert_failure 64
  assert_output --partial "--reason に閉じる理由を書いてください"
  assert_equal "$(writes)" ""
}

@test "既に閉じている Issue では、コメントもせずに止まる" {
  setup_cancel
  cancel_issue 17 CLOSED COMPLETED "完了しました"
  run_script issue-cancel.sh --issue 17 --reason "やらないことにしました"
  assert_failure 2
  assert_output --partial "Issue #17 は既に閉じています"
  assert_equal "$(writes)" ""
}

@test "同じ閉じ方でも理由が違えば、既に閉じているとして止まる" {
  setup_cancel
  cancel_issue 17 CLOSED NOT_PLANNED "前に閉じたときの理由"
  run_script issue-cancel.sh --issue 17 --reason "やらないことにしました"
  assert_failure 2
  assert_output --partial "Issue #17 は既に閉じています"
}

@test "同じ理由・同じ閉じ方で既に閉じていれば（前回の続き）、何もせずに成功する" {
  setup_cancel
  cancel_issue 17 CLOSED NOT_PLANNED "やらないことにしました"
  run_script issue-cancel.sh --issue 17 --reason "やらないことにしました"
  assert_success
  assert_equal "$(writes)" ""
  assert_equal "$(jq -c '[.commented, .closed, .actions]' <<<"$output")" '[false,false,[]]'
}

@test "無い Issue や PR の番号ならエラーになる" {
  setup_cancel
  run_script issue-cancel.sh --issue 99 --reason "やらないことにしました"
  assert_failure 2
  assert_output --partial "Issue #99 が me/demo にありません"
  echo '{"url": "https://github.com/me/demo/pull/21", "number": 21}' >"$FIX/issue-21.json"
  run_script issue-cancel.sh --issue 21 --reason "やらないことにしました"
  assert_failure 2
  assert_output --partial "#21 は PR です。Issue の番号を指定してください"
  assert_equal "$(writes)" ""
}

@test "Issue を読めなければ（見つからない以外）、理由を添えて止まる" {
  setup_cancel
  FAKE_FAIL=issue-view FAKE_FAIL_MSG="error connecting to api.github.com" \
    run_script issue-cancel.sh --issue 17 --reason "やらないことにしました"
  assert_failure 1
  assert_output --partial "Issue #17 を読めません: error connecting to api.github.com"
}

@test "dry-run では閉じず、予定だけを出力する" {
  setup_cancel
  run_script issue-cancel.sh --issue 17 --reason "やらないことにしました" --dry-run
  assert_success
  assert_equal "$(writes)" ""
  assert_equal "$(jq -r .dry_run <<<"$output")" true
  assert_equal "$(jq -c .actions <<<"$output")" \
    '["Issue #17 に閉じる理由をコメントする","Issue #17 を not planned で閉じる（Project と Story Point はそのまま残す）"]'
}

@test "コメントに失敗したら、閉じずに止まる" {
  setup_cancel
  FAKE_FAIL=issue-comment run_script issue-cancel.sh --issue 17 --reason "やらないことにしました"
  assert_failure
  assert_output --partial "Issue #17 にコメントできませんでした"
  assert_equal "$(grep -c '^issue-close ' "$CALLS")" 0
}

@test "閉じるのに失敗したら、コメントは付いたことを伝えて止まる" {
  setup_cancel
  FAKE_FAIL=issue-close run_script issue-cancel.sh --issue 17 --reason "やらないことにしました"
  assert_failure
  assert_output --partial "Issue #17 にコメントしましたが、閉じられませんでした"
}

@test "最後のコメントが同じ理由なら（閉じるのに失敗した後の再実行）、コメントを付け直さずに閉じる" {
  setup_cancel
  cancel_issue 17 OPEN "" "やらないことにしました"
  run_script issue-cancel.sh --issue 17 --reason "やらないことにしました"
  assert_success
  assert_equal "$(writes)" "issue-close 17,"
  assert_equal "$(jq -r .commented <<<"$output")" false
}

@test "最後のコメントが違えば、コメントを付ける" {
  setup_cancel
  cancel_issue 17 OPEN "" "ほかのコメント"
  run_script issue-cancel.sh --issue 17 --reason "やらないことにしました"
  assert_success
  assert_equal "$(writes)" "issue-comment 17,issue-close 17,"
}

@test "--issue が数字でなければエラーになる" {
  setup_cancel
  run_script issue-cancel.sh --issue abc --reason "やらないことにしました"
  assert_failure 64
  assert_output --partial "--issue には数字を指定してください: abc"
}

@test "--branch を付けると、Issue → PR（コメントして閉じる）→ リモートのブランチの順に片付ける" {
  setup_cancel
  cancel_prs '[""]'
  touch "$FIX/remote-ref"
  run_script issue-cancel.sh --issue 17 --reason "やらないことにしました" --branch feat/17-x
  assert_success
  assert_equal "$(grep '^api-get ' "$CALLS")" "api-get repos/me/demo/git/ref/heads/feat/17-x"
  assert_equal "$(grep '^pr-list ' "$CALLS")" "pr-list --head feat/17-x --state open --json number,title,url,comments"
  assert_equal "$(cat "$TMP/pr-comment-body")" "やらないことにしました"
  assert_equal "$(writes)" "issue-comment 17,issue-close 17,pr-comment 42,pr-close 42,api-delete repos/me/demo/git/refs/heads/feat/17-x,"
  assert_equal "$(jq -c '[.branch, .pull_requests, .remote_branch_deleted]' <<<"$output")" \
    '["feat/17-x",[{"number":42,"title":"PR 42","url":"https://github.com/me/demo/pull/42","commented":true}],true]'
}

@test "PR が無ければ、リモートのブランチだけを削除する" {
  setup_cancel
  cancel_prs '[]'
  touch "$FIX/remote-ref"
  run_script issue-cancel.sh --issue 17 --reason "やらないことにしました" --branch feat/17-x
  assert_success
  assert_equal "$(writes)" "issue-comment 17,issue-close 17,api-delete repos/me/demo/git/refs/heads/feat/17-x,"
}

@test "リモートにブランチが無ければ、削除しない" {
  setup_cancel
  cancel_prs '[]'
  run_script issue-cancel.sh --issue 17 --reason "やらないことにしました" --branch feat/17-x
  assert_success
  assert_equal "$(grep -c '^api-delete ' "$CALLS")" 0
  assert_equal "$(jq -c '[.pull_requests, .remote_branch_deleted]' <<<"$output")" '[[],false]'
}

@test "リモートのブランチを確かめられなければ（404 以外）、何もせずに止まる" {
  setup_cancel
  FAKE_FAIL=api-get FAKE_FAIL_MSG="gh: Server Error (HTTP 500)" \
    run_script issue-cancel.sh --issue 17 --reason "やらないことにしました" --branch feat/17-x
  assert_failure
  assert_output --partial "リモートのブランチ feat/17-x を確かめられませんでした: gh: Server Error (HTTP 500)"
  assert_equal "$(writes)" ""
}

@test "PR の最後のコメントが同じ理由なら、コメントを付け直さずに閉じる" {
  setup_cancel
  cancel_prs '["やらないことにしました"]'
  run_script issue-cancel.sh --issue 17 --reason "やらないことにしました" --branch feat/17-x
  assert_success
  assert_equal "$(writes)" "issue-comment 17,issue-close 17,pr-close 42,"
}

@test "Issue を閉じた後に PR で失敗したら、再実行で Issue を飛ばして PR から続ける" {
  setup_cancel
  cancel_prs '[""]'
  touch "$FIX/remote-ref"
  FAKE_FAIL=pr-close run_script issue-cancel.sh --issue 17 --reason "やらないことにしました" --branch feat/17-x
  assert_failure
  assert_output --partial "Issue #17 は閉じましたが、PR #42 を閉じられませんでした（もう一度実行すると続きから進みます）"
  assert_equal "$(grep -c '^api-delete ' "$CALLS")" 0
  # 再実行：Issue は同じ理由で閉じていて、PR には同じ理由のコメントが付いている
  : >"$CALLS"
  cancel_issue 17 CLOSED NOT_PLANNED "やらないことにしました"
  cancel_prs '["やらないことにしました"]'
  run_script issue-cancel.sh --issue 17 --reason "やらないことにしました" --branch feat/17-x
  assert_success
  assert_equal "$(writes)" "pr-close 42,api-delete repos/me/demo/git/refs/heads/feat/17-x,"
}

@test "リモートのブランチの削除に失敗したら、そう伝えて止まる" {
  setup_cancel
  cancel_prs '[]'
  touch "$FIX/remote-ref"
  FAKE_FAIL=api-delete run_script issue-cancel.sh --issue 17 --reason "やらないことにしました" --branch feat/17-x
  assert_failure
  assert_output --partial "Issue #17 は閉じましたが、リモートのブランチ feat/17-x を削除できませんでした"
}

@test "--branch に base_branch は指定できない" {
  setup_cancel
  run_script issue-cancel.sh --issue 17 --reason "やらないことにしました" --branch main
  assert_failure 64
  assert_output --partial "main は削除できません"
  assert_equal "$(writes)" ""
}

@test "dry-run では PR とブランチにも触れず、予定だけを出力する" {
  setup_cancel
  cancel_prs '[""]'
  touch "$FIX/remote-ref"
  run_script issue-cancel.sh --issue 17 --reason "やらないことにしました" --branch feat/17-x --dry-run
  assert_success
  assert_equal "$(writes)" ""
  assert_equal "$(jq -c '.actions[2:]' <<<"$output")" \
    '["PR #42 に閉じる理由をコメントする","PR #42 をマージせずに閉じる","リモートのブランチ feat/17-x を削除する"]'
}
