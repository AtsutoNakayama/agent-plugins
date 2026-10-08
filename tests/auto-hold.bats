#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper
load fake_gh

# 保留の列（On Hold）を設定し、Project の Status に足す。止まった理由を $TMP/reason.md に書く
setup_hold() {
  setup_fake_gh
  echo '{"project": {"owner": "me", "number": 4}, "status": {"hold": "On Hold"}}' >.claude/dev-workflow/config.json
  jq '.[0].options += [{id: "O4", name: {raw: "On Hold"}}]' "$FIX/ProjectFields.json" >"$TMP/f.json" && mv "$TMP/f.json" "$FIX/ProjectFields.json"
  printf '## 止まった理由\n- テストが3回直しても通りません\n' >"$TMP/reason.md"
}

# 使い方: set_comments <最後のコメントの本文> → Issue #17 のコメントをその1件にする
set_comments() {
  jq --arg b "$1" '. + {comments: [{body: "前のコメント"}, {body: $b}]}' "$FIX/issue-17.json" >"$TMP/i.json" && mv "$TMP/i.json" "$FIX/issue-17.json"
}

run_hold() {
  run_script auto-hold.sh "$@"
  printf '%s\n' "$output"
}

@test "印を付けて理由をコメントし、保留の列に移す" {
  setup_hold
  set_comments "別の話"
  run_hold --issue '#17' --reason-file "$TMP/reason.md"
  assert_success
  assert_equal "$(jq -c '[.issue, .commented, .status.to, .dry_run]' <<<"$output")" '[17,true,"On Hold",false]'
  assert_equal "$(called issue-comment)" 1
  assert_equal "$(cat "$TMP/issue-comment-body")" "$(printf '<!-- dev-workflow:task-auto -->\n\n## 止まった理由\n- テストが3回直しても通りません')"
  assert_equal "$(args SetField | jq -r '."single-select-option-id"')" O4
}

@test "最後のコメントが同じ本文なら付け直さず、列だけを移す（途中で止まったときの再実行）" {
  setup_hold
  set_comments "$(printf '<!-- dev-workflow:task-auto -->\n\n## 止まった理由\n- テストが3回直しても通りません')"
  run_hold --issue 17 --reason-file "$TMP/reason.md"
  assert_success
  assert_equal "$(jq -r .commented <<<"$output")" false
  assert_equal "$(called issue-comment)" 0
  assert_equal "$(called SetField)" 1
}

@test "--dry-run は、コメントも列の移動もせず、予定と本文を出す" {
  setup_hold
  set_comments "別の話"
  run_hold --issue 17 --reason-file "$TMP/reason.md" --dry-run
  assert_success
  assert_equal "$(jq -c '[.commented, .status, .dry_run]' <<<"$output")" '[true,null,true]'
  assert_output --partial "保留の列「On Hold」に移す"
  assert_equal "$(called issue-comment)" 0
  assert_equal "$(called SetField)" 0
}

@test "保留の列が無ければ、何もせずに止まる" {
  setup_hold
  echo '{"project": {"owner": "me", "number": 4}}' >.claude/dev-workflow/config.json
  run_hold --issue 17 --reason-file "$TMP/reason.md"
  assert_failure 2
  assert_output --partial "保留の列（status.hold）が設定されていません"
  assert_equal "$(called issue-view)" 0
  assert_equal "$(called issue-comment)" 0
}

@test "本文が空（空白だけ）なら、何もせずに止まる" {
  setup_hold
  printf ' \n\t\n' >"$TMP/reason.md"
  run_hold --issue 17 --reason-file "$TMP/reason.md"
  assert_failure 2
  assert_output --partial "コメントの本文（止まった理由）が空です"
  assert_equal "$(called issue-comment)" 0
}

@test "コメントできなければ、列を移さずに止まる" {
  setup_hold
  set_comments "別の話"
  FAKE_FAIL=issue-comment run_hold --issue 17 --reason-file "$TMP/reason.md"
  assert_failure 1
  assert_output --partial "Issue #17 にコメントできませんでした"
  assert_equal "$(called SetField)" 0
}

@test "列を移せなければ、もう一度実行すればよいと伝えて止まる" {
  setup_hold
  set_comments "別の話"
  FAKE_FAIL=SetField run_hold --issue 17 --reason-file "$TMP/reason.md"
  assert_failure 1
  assert_output --partial "保留の列「On Hold」に移せませんでした（もう一度実行すれば"
}

@test "本文は標準入力からも読める" {
  setup_hold
  set_comments "別の話"
  run_script auto-hold.sh --issue 17 --reason-file - <"$TMP/reason.md"
  assert_success
  assert_equal "$(called issue-comment)" 1
}

@test "コメントが1件も無ければ、コメントして列を移す" {
  setup_hold
  jq '. + {comments: []}' "$FIX/issue-17.json" >"$TMP/i.json" && mv "$TMP/i.json" "$FIX/issue-17.json"
  run_hold --issue 17 --reason-file "$TMP/reason.md"
  assert_success
  assert_equal "$(jq -r .commented <<<"$output")" true
  assert_equal "$(called issue-comment)" 1
  assert_equal "$(called SetField)" 1
}

@test "同じ本文のコメントが最後でなくても（後に誰かが書いても）、付け直さない" {
  setup_hold
  jq --arg b "$(printf '<!-- dev-workflow:task-auto -->\n\n## 止まった理由\n- テストが3回直しても通りません')" \
    '. + {comments: [{body: $b}, {body: "後から書いたコメント"}]}' "$FIX/issue-17.json" >"$TMP/i.json" && mv "$TMP/i.json" "$FIX/issue-17.json"
  run_hold --issue 17 --reason-file "$TMP/reason.md"
  assert_success
  assert_equal "$(jq -r .commented <<<"$output")" false
  assert_equal "$(called issue-comment)" 0
}

@test "コメントを付け直さなかった再実行で列を移せなければ、コメントしたとは伝えない" {
  setup_hold
  set_comments "$(printf '<!-- dev-workflow:task-auto -->\n\n## 止まった理由\n- テストが3回直しても通りません')"
  FAKE_FAIL=SetField run_hold --issue 17 --reason-file "$TMP/reason.md"
  assert_failure 1
  refute_output --partial "コメントしましたが"
  assert_output --partial "保留の列「On Hold」に移せませんでした（同じコメントは既にあります。もう一度実行すれば"
}

@test "本文のファイルが無い・保留の列がほかの役割と同じ名前なら、何もせずに止まる" {
  setup_hold
  run_hold --issue 17 --reason-file "$TMP/none.md"
  assert_failure 64
  assert_output --partial "本文のファイルがありません"
  echo '{"project": {"owner": "me", "number": 4}, "status": {"hold": "Todo"}}' >.claude/dev-workflow/config.json
  run_hold --issue 17 --reason-file "$TMP/reason.md"
  assert_failure 2
  assert_output --partial "保留の列（status.hold）は、ほかの役割（status.todo）と別の列名にしてください"
  assert_equal "$(called issue-view)" 0
  assert_equal "$(called issue-comment)" 0
}
