#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper
load fake_gh

# 実行 r1 の印を付けた本文（$TMP/reason.md の中身）
R1_BODY="$(printf '<!-- dev-workflow:task-auto run=r1 -->\n\n## 止まった理由\n- テストが3回直しても通りません')"

# 保留の列（On Hold）を設定し、Project の Status に足す。止まった理由を $TMP/reason.md に書く
setup_hold() {
  setup_fake_gh
  echo '{"project": {"owner": "me", "number": 4}, "status": {"hold": "On Hold"}}' >.claude/dev-workflow/config.json
  jq '.[0].options += [{id: "O4", name: {raw: "On Hold"}}]' "$FIX/ProjectFields.json" >"$TMP/f.json" && mv "$TMP/f.json" "$FIX/ProjectFields.json"
  printf '## 止まった理由\n- テストが3回直しても通りません\n' >"$TMP/reason.md"
}

# 使い方: set_comments <本文>... → Issue #17 のコメントを、その本文のコメントにする（上から古い順）
set_comments() {
  jq -n '$ARGS.positional | map({body: .})' --args "$@" >"$TMP/c.json"
  jq --slurpfile c "$TMP/c.json" '. + {comments: $c[0]}' "$FIX/issue-17.json" >"$TMP/i.json" && mv "$TMP/i.json" "$FIX/issue-17.json"
}

# 実行の id を r1 にして auto-hold.sh を実行する（--run-id を渡せば、それを使う）
run_hold() {
  case " $* " in
    *" --run-id "*) run_script auto-hold.sh "$@" ;;
    *) run_script auto-hold.sh --run-id r1 "$@" ;;
  esac
  printf '%s\n' "$output"
}

@test "実行の id を入れた印を付けて理由をコメントし、保留の列に移す" {
  setup_hold
  set_comments "別の話"
  run_hold --issue '#17' --reason-file "$TMP/reason.md"
  assert_success
  assert_equal "$(jq -c '[.issue, .commented, .status.to, .dry_run]' <<<"$output")" '[17,true,"On Hold",false]'
  assert_equal "$(called issue-comment)" 1
  assert_equal "$(cat "$TMP/issue-comment-body")" "$R1_BODY"
  assert_equal "$(args SetField | jq -r '."single-select-option-id"')" O4
}

@test "コメントが1件も無ければ、コメントして列を移す" {
  setup_hold
  set_comments
  run_hold --issue 17 --reason-file "$TMP/reason.md"
  assert_success
  assert_equal "$(jq -r .commented <<<"$output")" true
  assert_equal "$(called issue-comment)" 1
  assert_equal "$(called SetField)" 1
}

@test "同じ実行のコメントがあれば、後に人のコメントがあっても付け直さず、列だけを移す（途中で止まったときの再試行）" {
  setup_hold
  set_comments "$R1_BODY" "後から書いたコメント"
  run_hold --issue 17 --reason-file "$TMP/reason.md"
  assert_success
  assert_equal "$(jq -r .commented <<<"$output")" false
  assert_equal "$(called issue-comment)" 0
  assert_equal "$(called SetField)" 1
}

@test "別の実行なら、理由が前と同じでもコメントする（新しく止まったことを Issue に残す）" {
  setup_hold
  # 前の実行 r1 で同じ理由で止まり、間に成功した実行（コメントしない）があった後、実行 r2 でまた同じ理由で止まった
  set_comments "$R1_BODY" "人のコメント"
  run_hold --issue 17 --run-id r2 --reason-file "$TMP/reason.md"
  assert_success
  assert_equal "$(jq -r .commented <<<"$output")" true
  assert_equal "$(head -n 1 "$TMP/issue-comment-body")" "<!-- dev-workflow:task-auto run=r2 -->"
}

@test "--run-id が無い・使えない文字があれば、何もせずに止まる" {
  setup_hold
  run_script auto-hold.sh --issue 17 --reason-file "$TMP/reason.md"
  assert_failure 64
  assert_output --partial "--run-id は必須です"
  for id in 'a b' 'r1-->' 'x;y'; do
    run_hold --issue 17 --run-id "$id" --reason-file "$TMP/reason.md"
    assert_failure 64
    assert_output --partial "--run-id には英数字と . _ - だけを使ってください"
  done
  assert_equal "$(called issue-view)" 0
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
  assert_output --partial "Issue #17 にコメントしましたが、保留の列「On Hold」に移せませんでした（もう一度実行すれば"
}

@test "コメントを付け直さなかった再試行で列を移せなければ、コメントしたとは伝えない" {
  setup_hold
  set_comments "$R1_BODY"
  FAKE_FAIL=SetField run_hold --issue 17 --reason-file "$TMP/reason.md"
  assert_failure 1
  refute_output --partial "コメントしましたが"
  assert_output --partial "保留の列「On Hold」に移せませんでした（この実行のコメントは既にあります。もう一度実行すれば"
}

@test "本文は標準入力からも読める" {
  setup_hold
  set_comments "別の話"
  run_hold --issue 17 --reason-file - <"$TMP/reason.md"
  assert_success
  assert_equal "$(called issue-comment)" 1
}

@test "止まった理由が長くても（引数の長さの上限の 128 KiB を超えても）、コメントして列を移す" {
  setup_hold
  set_comments
  # 絵文字（BMP の外の文字）も混ぜ、読み込みの区切りで割れないことも確かめる
  long_text "$TMP/reason.md" 'あ😀'
  run_hold --issue 17 --reason-file "$TMP/reason.md"
  assert_success
  assert_equal "$(jq -c '[.commented, (.comment | length > 60000)]' <<<"$output")" '[true,true]'
  assert_equal "$(cat "$TMP/issue-comment-body")" "$(printf '<!-- dev-workflow:task-auto run=r1 -->\n\n%s' "$(cat "$TMP/reason.md")")"
  assert_equal "$(jq -r .comment <<<"$output")" "$(cat "$TMP/issue-comment-body")"
}

@test "--repair-reason を渡すと、実行の印の次の行に、止まった理由の種類の印を足す（#332）" {
  setup_hold
  set_comments "別の話"
  run_hold --issue 17 --reason-file "$TMP/reason.md" --repair-reason same_failure
  assert_success
  assert_equal "$(head -n 2 "$TMP/issue-comment-body")" "$(printf '%s\n%s' '<!-- dev-workflow:task-auto run=r1 -->' '<!-- dev-workflow:repair-stopped reason=same_failure -->')"
  assert_equal "$(sed -n '4,$p' "$TMP/issue-comment-body")" "$(cat "$TMP/reason.md")"
  # 出力の comment にも同じ本文が入る
  assert_equal "$(jq -r .comment <<<"$output")" "$(cat "$TMP/issue-comment-body")"
}

@test "--repair-reason があっても、同じ実行のコメントがあれば付け直さない（先頭は実行の印のまま）" {
  setup_hold
  set_comments "$(printf '<!-- dev-workflow:task-auto run=r1 -->\n<!-- dev-workflow:repair-stopped reason=dirty -->\n\n理由')"
  run_hold --issue 17 --reason-file "$TMP/reason.md" --repair-reason dirty
  assert_success
  assert_equal "$(jq -r .commented <<<"$output")" false
  assert_equal "$(called issue-comment)" 0
  assert_equal "$(called SetField)" 1
}

@test "--repair-reason が無ければ、理由の種類の印を足さない" {
  setup_hold
  set_comments "別の話"
  run_hold --issue 17 --reason-file "$TMP/reason.md"
  assert_success
  refute_output --partial "repair-stopped"
}

@test "--repair-reason に使えない文字があれば、何もせずに止まる（印を閉じさせない）" {
  setup_hold
  for r in 'Dirty' 'same-failure' 'x -->' '1abc' '_x' 'a;b'; do
    run_hold --issue 17 --reason-file "$TMP/reason.md" --repair-reason "$r"
    assert_failure 64
    assert_output --partial "--repair-reason"
  done
  run_hold --issue 17 --reason-file "$TMP/reason.md" --repair-reason
  assert_failure 64
  assert_equal "$(called issue-view)" 0
  assert_equal "$(called issue-comment)" 0
}
