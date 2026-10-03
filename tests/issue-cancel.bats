#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper
load fake_gh

# 閉じる Issue #17 の状態。使い方: cancel_issue [状態（既定 OPEN）] [stateReason] [最後のコメント]
cancel_issue() {
  jq -n --arg s "${1:-OPEN}" --arg r "${2:-}" --arg c "${3:-}" '{data: {repository: {issue: {
    id: "I17", number: 17, title: "作業 17", state: $s, stateReason: (if $r == "" then null else $r end),
    comments: {nodes: (if $c == "" then [] else [{body: $c}] end)}}}}}' >"$FIX/CancelIssue.json"
}

setup_cancel() {
  setup_fake_gh
  cancel_issue
  echo '{"data": {"repository": {"issue": {"id": "I20", "number": 20}}}}' >"$FIX/CancelDuplicate.json"
}

@test "理由をコメントして not planned で閉じる" {
  setup_cancel
  run_script issue-cancel.sh --issue 17 --reason "#20 で作業するため閉じます"
  assert_success
  assert_equal "$(args AddComment)" '{"id":"I17","body":"#20 で作業するため閉じます"}'
  assert_equal "$(args CloseIssue)" '{"id":"I17","reason":"NOT_PLANNED","dup":null}'
  # コメントしてから閉じる
  assert_equal "$(grep -oE '^(AddComment|CloseIssue)' "$CALLS" | tr '\n' ' ')" "AddComment CloseIssue "
  assert_equal "$(jq -c '[.issue, .title, .dry_run, .state_reason, .duplicate_of, .comment, .commented, .closed]' <<<"$output")" \
    '[17,"作業 17",false,"NOT_PLANNED",null,"#20 で作業するため閉じます",true,true]'
}

@test "複数行の理由もそのままコメントする" {
  setup_cancel
  run_script issue-cancel.sh --issue 17 --reason "$(printf '誤って起票しました。\n\n代わりに #20 で作業します。')"
  assert_success
  assert_equal "$(args AddComment | jq -r .body)" "$(printf '誤って起票しました。\n\n代わりに #20 で作業します。')"
}

@test "--duplicate-of を付けると、元の Issue に紐付けて duplicate で閉じる" {
  setup_cancel
  run_script issue-cancel.sh --issue 17 --reason "#20 と同じ内容なので閉じます" --duplicate-of 20
  assert_success
  assert_equal "$(args CancelDuplicate | jq -c .number)" 20
  assert_equal "$(args CloseIssue)" '{"id":"I17","reason":"DUPLICATE","dup":"I20"}'
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

@test "重複の元の Issue が無ければ、何もせずに止まる" {
  setup_cancel
  FAKE_FAIL=CancelDuplicate FAKE_FAIL_MSG="GraphQL: Could not resolve to an Issue with the number of 99. (repository.issue)" \
    run_script issue-cancel.sh --issue 17 --reason "重複です" --duplicate-of 99
  assert_failure 2
  assert_output --partial "重複の元の Issue #99 が me/demo にありません"
  assert_equal "$(called AddComment)" 0
  assert_equal "$(called CloseIssue)" 0
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
  # Project の操作（項目の追加・値の設定）を呼ばない
  assert_equal "$(grep -vEc '^(CancelIssue|AddComment|CloseIssue) ' "$CALLS")" 0
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
  assert_equal "$(called AddComment)" 0
  assert_equal "$(called CloseIssue)" 0
}

@test "既に閉じている Issue では、コメントもせずに止まる" {
  setup_cancel
  cancel_issue CLOSED COMPLETED "完了しました"
  run_script issue-cancel.sh --issue 17 --reason "やらないことにしました"
  assert_failure 2
  assert_output --partial "Issue #17 は既に閉じています"
  assert_equal "$(called AddComment)" 0
  assert_equal "$(called CloseIssue)" 0
}

@test "同じ閉じ方でも理由が違えば、既に閉じているとして止まる" {
  setup_cancel
  cancel_issue CLOSED NOT_PLANNED "前に閉じたときの理由"
  run_script issue-cancel.sh --issue 17 --reason "やらないことにしました"
  assert_failure 2
  assert_output --partial "Issue #17 は既に閉じています"
}

@test "同じ理由・同じ閉じ方で既に閉じていれば（前回の続き）、何もせずに成功する" {
  setup_cancel
  cancel_issue CLOSED NOT_PLANNED "やらないことにしました"
  run_script issue-cancel.sh --issue 17 --reason "やらないことにしました"
  assert_success
  assert_equal "$(called AddComment)" 0
  assert_equal "$(called CloseIssue)" 0
  assert_equal "$(jq -c '[.commented, .closed, .actions]' <<<"$output")" '[false,false,[]]'
}

@test "無い Issue（PR の番号を含む）ならエラーになる" {
  setup_cancel
  FAKE_FAIL=CancelIssue FAKE_FAIL_MSG="GraphQL: Could not resolve to an Issue with the number of 99. (repository.issue)" \
    run_script issue-cancel.sh --issue 99 --reason "やらないことにしました"
  assert_failure 2
  assert_output --partial "Issue #99 が me/demo にありません"
  assert_equal "$(called CloseIssue)" 0
}

@test "dry-run では閉じず、予定だけを出力する" {
  setup_cancel
  run_script issue-cancel.sh --issue 17 --reason "やらないことにしました" --dry-run
  assert_success
  assert_equal "$(called AddComment)" 0
  assert_equal "$(called CloseIssue)" 0
  assert_equal "$(jq -r .dry_run <<<"$output")" true
  assert_equal "$(jq -c .actions <<<"$output")" \
    '["Issue #17 に閉じる理由をコメントする","Issue #17 を not planned で閉じる（Project と Story Point はそのまま残す）"]'
}

@test "コメントに失敗したら、閉じずに止まる" {
  setup_cancel
  FAKE_FAIL=AddComment run_script issue-cancel.sh --issue 17 --reason "やらないことにしました"
  assert_failure
  assert_output --partial "Issue #17 にコメントできませんでした"
  assert_equal "$(called CloseIssue)" 0
}

@test "閉じるのに失敗したら、コメントは付いたことを伝えて止まる" {
  setup_cancel
  FAKE_FAIL=CloseIssue run_script issue-cancel.sh --issue 17 --reason "やらないことにしました"
  assert_failure
  assert_output --partial "Issue #17 にコメントしましたが、閉じられませんでした"
}

@test "最後のコメントが同じ理由なら（閉じるのに失敗した後の再実行）、コメントを付け直さずに閉じる" {
  setup_cancel
  cancel_issue OPEN "" "やらないことにしました"
  run_script issue-cancel.sh --issue 17 --reason "やらないことにしました"
  assert_success
  assert_equal "$(called AddComment)" 0
  assert_equal "$(called CloseIssue)" 1
  assert_equal "$(jq -r .commented <<<"$output")" false
}

@test "最後のコメントが違えば、コメントを付ける" {
  setup_cancel
  cancel_issue OPEN "" "ほかのコメント"
  run_script issue-cancel.sh --issue 17 --reason "やらないことにしました"
  assert_success
  assert_equal "$(called AddComment)" 1
}

@test "--issue が数字でなければエラーになる" {
  setup_cancel
  run_script issue-cancel.sh --issue abc --reason "やらないことにしました"
  assert_failure 64
  assert_output --partial "--issue には数字を指定してください: abc"
}
