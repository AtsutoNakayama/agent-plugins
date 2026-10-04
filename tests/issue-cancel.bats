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
  jq -n --argjson c "$1" '$c | to_entries | map({number: (.key + 42), title: "PR \(.key + 42)", isCrossRepository: false,
    url: "https://github.com/me/demo/pull/\(.key + 42)", comments: (if .value == "" then [] else [{body: .value}] end)})' \
    >"$FIX/pr-list.json"
}

setup_cancel() {
  setup_fake_gh
  cancel_issue 17
  cancel_issue 20
}

# REST の issues/<親>/sub_issues が返す子。使い方: sub_issue <番号> <open | closed> [孫の数（既定 0）] [所有者/名前（既定 me/demo）]
sub_issue() {
  jq -nc --argjson n "$1" --arg s "$2" --argjson t "${3:-0}" --arg r "${4:-me/demo}" '{number: $n, title: "子 \($n)",
    state: $s, html_url: "https://github.com/\($r)/issues/\($n)", url: "https://api.github.com/repos/\($r)/issues/\($n)",
    repository_url: "https://api.github.com/repos/\($r)",
    sub_issues_summary: {total: $t}}'
}

# 親 <番号> の子を設定する。使い方: set_subs <親の番号> <sub_issue の出力>...
set_subs() {
  local parent="$1"
  shift
  printf '%s\n' "$@" | jq -s . >"$FIX/sub-issues-$parent.json"
}

# 17 の下に、開いている子 30（その下に開いている孫 31）と、閉じた子 32 を置く
sub_tree() {
  set_subs 17 "$(sub_issue 30 open 1)" "$(sub_issue 32 closed)"
  set_subs 30 "$(sub_issue 31 open)"
  cancel_issue 30
  cancel_issue 31
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

@test "--duplicate-of が # だけなら、not planned で閉じずに止まる" {
  setup_cancel
  run_script issue-cancel.sh --issue 17 --reason "重複です" --duplicate-of '#'
  assert_failure 64
  assert_output --partial "--duplicate-of に値がありません"
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
  # Project の操作（GraphQL）もラベルなどの変更（issue edit）も呼ばない（Issue とサブ Issue の読み取りは数えない）
  assert_equal "$(grep -vEc '^(issue-view|api-sub-issues|issue-comment|issue-close) ' "$CALLS")" 0
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
  assert_equal "$(grep '^pr-list ' "$CALLS")" "pr-list --head feat/17-x --state open --json number,title,url,isCrossRepository,comments"
  assert_equal "$(cat "$TMP/pr-comment-body")" "やらないことにしました"
  assert_equal "$(writes)" "issue-comment 17,issue-close 17,pr-comment 42,pr-close 42,api-delete repos/me/demo/git/refs/heads/feat/17-x,"
  assert_equal "$(jq -c '[.branch, .pull_requests, .remote_branch_deleted]' <<<"$output")" \
    '["feat/17-x",[{"number":42,"title":"PR 42","url":"https://github.com/me/demo/pull/42","commented":true}],true]'
}

@test "ほかの人の fork から出た同じ名前のブランチの PR は閉じない" {
  setup_cancel
  # 42 はこのリポジトリのブランチ、43 は fork の同じ名前のブランチから出た PR
  jq -n '[{number: 42, title: "PR 42", url: "u42", isCrossRepository: false, comments: []},
    {number: 43, title: "PR 43", url: "u43", isCrossRepository: true, comments: []}]' >"$FIX/pr-list.json"
  touch "$FIX/remote-ref"
  run_script issue-cancel.sh --issue 17 --reason "やらないことにしました" --branch feat/17-x
  assert_success
  assert_equal "$(writes)" "issue-comment 17,issue-close 17,pr-comment 42,pr-close 42,api-delete repos/me/demo/git/refs/heads/feat/17-x,"
  assert_equal "$(jq -c '[.pull_requests[].number]' <<<"$output")" '[42]'
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

@test "開いている子孫があるのに --sub-issues が無ければ、子孫を挙げて何もせずに止まる（dry-run も同じ）" {
  setup_cancel
  sub_tree
  for mode in --dry-run ""; do
    run_script issue-cancel.sh --issue 17 --reason "方針が変わったのでやめます" ${mode:+"$mode"}
    assert_failure 2
    assert_output "error: Issue #17 には開いている子の Issue（#30, #31）があります。--sub-issues で、一緒に閉じる（close）か残す（keep）かを指定してください"
  done
  assert_equal "$(writes)" ""
}

@test "--sub-issues close なら、開いている子孫を深いものから閉じてから、親を閉じる" {
  setup_cancel
  sub_tree
  run_script issue-cancel.sh --issue 17 --reason "方針が変わったのでやめます" --sub-issues close
  assert_success
  assert_equal "$(writes)" "issue-comment 31,issue-close 31,issue-comment 30,issue-close 30,issue-comment 17,issue-close 17,"
  assert_equal "$(grep -c "^issue-close 3[01] --reason not planned$" "$CALLS")" 2
  # 閉じた子 32 の下は読まず、孫を持つ子 30 の下だけを読む
  assert_equal "$(grep '^api-sub-issues ' "$CALLS" | tr '\n' ,)" \
    "api-sub-issues repos/me/demo/issues/17/sub_issues,api-sub-issues repos/me/demo/issues/30/sub_issues,"
  assert_equal "$(jq -c '.sub_issues | [.action, (.open | map([.number, .commented]))]' <<<"$output")" \
    '["close",[[30,true],[31,true]]]'
}

@test "--sub-issues keep なら、子孫には触れずに親だけを閉じる" {
  setup_cancel
  sub_tree
  run_script issue-cancel.sh --issue 17 --reason "親だけやめます" --sub-issues keep
  assert_success
  assert_equal "$(writes)" "issue-comment 17,issue-close 17,"
  assert_equal "$(jq -c '.sub_issues | [.action, (.open | map(.number))]' <<<"$output")" '["keep",[30,31]]'
}

@test "子がすべて閉じていれば、--sub-issues が無くても親を閉じる" {
  setup_cancel
  set_subs 17 "$(sub_issue 32 closed)"
  run_script issue-cancel.sh --issue 17 --reason "やめます"
  assert_success
  assert_equal "$(writes)" "issue-comment 17,issue-close 17,"
  assert_equal "$(jq -c .sub_issues <<<"$output")" '{"action":null,"open":[]}'
}

@test "開いている子孫に別のリポジトリの Issue があれば、--sub-issues を付けても何もせずに止まる" {
  setup_cancel
  set_subs 17 "$(sub_issue 30 open 1)" "$(sub_issue 39 closed 0 other/repo)"
  set_subs 30 "$(sub_issue 40 open 0 other/repo)"
  cancel_issue 30
  for mode in close keep; do
    run_script issue-cancel.sh --issue 17 --reason "やめます" --sub-issues "$mode"
    assert_failure 2
    assert_output "error: Issue #17 の開いている子孫に、別のリポジトリの Issue（other/repo#40）があります。その Issue を親から外すか、そのリポジトリで取りやめてから、もう一度実行してください"
  done
  assert_equal "$(writes)" ""
}

@test "子を閉じるのに失敗したら、親には触れずに止まる。再実行では、同じ理由をコメント済みの子にはコメントし直さない" {
  setup_cancel
  sub_tree
  FAKE_FAIL=issue-close run_script issue-cancel.sh --issue 17 --reason "やめます" --sub-issues close
  assert_failure 1
  assert_output --partial "子の Issue #31 を閉じられませんでした（もう一度実行すると続きから進みます）"
  assert_equal "$(writes)" "issue-comment 31,issue-close 31,"
  cancel_issue 31 OPEN "" "やめます"
  : >"$CALLS"
  run_script issue-cancel.sh --issue 17 --reason "やめます" --sub-issues close
  assert_success
  assert_equal "$(writes | cut -d, -f1)" "issue-close 31"
  assert_equal "$(jq -c '.sub_issues.open | map(.commented)' <<<"$output")" '[true,false]'
}

@test "dry-run では子孫も閉じず、予定だけを出力する" {
  setup_cancel
  sub_tree
  run_script issue-cancel.sh --issue 17 --reason "やめます" --sub-issues close --dry-run
  assert_success
  assert_equal "$(writes)" ""
  assert_equal "$(jq -r '.actions[0:4] | join(",")' <<<"$output")" \
    "子の Issue #31 に閉じる理由をコメントする,子の Issue #31 を not planned で閉じる（Project と Story Point はそのまま残す）,子の Issue #30 に閉じる理由をコメントする,子の Issue #30 を not planned で閉じる（Project と Story Point はそのまま残す）"
}

@test "--sub-issues が close・keep 以外ならエラーになる" {
  setup_cancel
  run_script issue-cancel.sh --issue 17 --reason "やめます" --sub-issues all
  assert_failure 64
  assert_output --partial "--sub-issues には close か keep を指定してください: all"
}

@test "サブ Issue を読めなければ、何もせずに止まる" {
  setup_cancel
  FAKE_FAIL=api-sub-issues run_script issue-cancel.sh --issue 17 --reason "やめます"
  assert_failure
  assert_output --partial "#17 のサブ Issue を読めませんでした"
  assert_equal "$(writes)" ""
}

@test "github.com 以外のホスト（GHES など）の子も、開いている子孫として数える" {
  setup_cancel
  jq -n '[{number: 50, title: "子 50", state: "open", html_url: "https://ghe.example.com/me/demo/issues/50",
    url: "https://ghe.example.com/api/v3/repos/me/demo/issues/50", repository_url: "https://ghe.example.com/api/v3/repos/me/demo",
    sub_issues_summary: {total: 0}}]' >"$FIX/sub-issues-17.json"
  run_script issue-cancel.sh --issue 17 --reason "やめます"
  assert_failure 2
  assert_output --partial "開いている子の Issue（#50）があります"
}

@test "理由の末尾が改行でも、同じ理由をコメント済みの子にはコメントし直さない" {
  setup_cancel
  set_subs 17 "$(sub_issue 30 open)"
  jq -n '{url: "https://github.com/me/demo/issues/30", number: 30, title: "作業 30", state: "OPEN", stateReason: "",
    comments: [{body: "やめます\n"}]}' >"$FIX/issue-30.json"
  run_script issue-cancel.sh --issue 17 --reason "$(printf 'やめます\nx')" --sub-issues close --dry-run
  assert_equal "$(jq -c '.sub_issues.open | map(.commented)' <<<"$output")" '[true]'
  run_script issue-cancel.sh --issue 17 --reason $'やめます\n' --sub-issues close
  assert_success
  assert_equal "$(jq -c '.sub_issues.open | map(.commented)' <<<"$output")" '[false]'
  assert_equal "$(writes | cut -d, -f1)" "issue-close 30"
}

@test "子の応答に孫の数（sub_issues_summary）が無くても、その子の下を読む" {
  setup_cancel
  set_subs 17 "$(sub_issue 30 open | jq -c 'del(.sub_issues_summary)')"
  set_subs 30 "$(sub_issue 31 open)"
  run_script issue-cancel.sh --issue 17 --reason "やめます"
  assert_failure 2
  assert_output --partial "開いている子の Issue（#30, #31）があります"
}
