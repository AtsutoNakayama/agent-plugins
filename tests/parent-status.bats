#!/usr/bin/env bats
# 子を start の列に移したときの、親の Issue の列の移動（status-set.sh）と、親の状態の取得（parent-state.sh）
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper
load fake_gh

# REST の issues/<子>/parent が返す親。使い方: set_parent <子の番号> <親の番号> [open | closed] [所有者/名前（既定 me/demo）] [state_reason]
set_parent() {
  jq -nc --argjson n "$2" --arg s "${3:-open}" --arg r "${4:-me/demo}" --arg sr "${5:-}" '{number: $n, title: "親 \($n)", state: $s,
    state_reason: (if $sr == "" then null else $sr end), url: "https://api.github.com/repos/\($r)/issues/\($n)",
    repository_url: "https://api.github.com/repos/\($r)"}' >"$FIX/parent-$1.json"
}

# 親（など）の Issue の Project P4 での項目と今の列。使い方: item_of <番号> <列名 | absent>
item_of() {
  jq -n --argjson n "$1" --arg s "$2" '{data: {repository: {issue: {url: "https://github.com/me/demo/issues/\($n)", projectItems: {nodes: (
    if $s == "absent" then [] else [{id: "IT\($n)", project: {id: "P4"}, fieldValueByName: {name: $s}}] end)}}}}}' >"$FIX/IssueItem-issue-$1.json"
}

setup_parents() {
  setup_fake_gh
  # 17 → 10 → 5
  set_parent 17 10
  set_parent 10 5
  item_of 17 Todo
  item_of 10 Todo
  item_of 5 Todo
}

moved() { grep '^SetField ' "$CALLS" | cut -d' ' -f2- | jq -r '.id' | tr '\n' ','; }

@test "子を start に移すと、todo の列にある親と上の親も start に移る" {
  setup_parents
  run_script status-set.sh --issue 17 --to start
  assert_success
  assert_equal "$(moved)" "IT17,IT10,IT5,"
  assert_equal "$(jq -c '[.parents[] | [.issue, .from, .to]]' <<<"$output")" '[[10,"Todo","In Progress"],[5,"Todo","In Progress"]]'
  assert_equal "$(jq -c '.actions' <<<"$output")" \
    '["Issue #17 を「Todo」から「In Progress」に移す","親の Issue #10 を「Todo」から「In Progress」に移す","親の Issue #5 を「Todo」から「In Progress」に移す"]'
}

@test "task-start でも親が start に移り、結果に出る" {
  setup_parents
  git init -q -b main "$TMP/origin.git" --bare
  git -C "$REPO" remote add origin "$TMP/origin.git"
  git add .claude/dev-workflow/config.json
  git -c user.name=t -c user.email=t@example.com commit -q -m config
  git push -q origin main
  run_script task-start.sh --issue 17 --slug x
  assert_success
  assert_equal "$(moved)" "IT17,IT10,IT5,"
  assert_equal "$(json_of "$output" | jq -c '[.status.parents[].issue]')" "[10,5]"
  assert_equal "$(json_of "$output" | jq -c '.actions | map(select(startswith("親の"))) | length')" 2
}

@test "todo より先の列にある親は動かさない（上の親は todo なら移す）" {
  setup_parents
  item_of 10 "In Progress"
  run_script status-set.sh --issue 17 --to start
  assert_success
  assert_equal "$(moved)" "IT17,IT5,"
}

@test "Done の列にある親も動かさない" {
  setup_parents
  item_of 10 Done
  run_script status-set.sh --issue 17 --to start
  assert_success
  assert_equal "$(moved)" "IT17,IT5,"
}

@test "閉じた親は動かさない" {
  setup_parents
  set_parent 17 10 closed me/demo completed
  run_script status-set.sh --issue 17 --to start
  assert_success
  assert_equal "$(moved)" "IT17,IT5,"
}

@test "Project に入っていない親は、追加も移動もしない" {
  setup_parents
  item_of 10 absent
  run_script status-set.sh --issue 17 --to start
  assert_success
  assert_equal "$(called AddItem)" 0
  assert_equal "$(moved)" "IT17,IT5,"
}

@test "別のリポジトリの親は動かさず、そこから上もたどらない" {
  setup_parents
  set_parent 17 10 open other/repo
  run_script status-set.sh --issue 17 --to start
  assert_success
  assert_equal "$(moved)" "IT17,"
  assert_equal "$(jq -c .parents <<<"$output")" "[]"
}

@test "start 以外の列（pr_opened・Done）に移すときは、親を動かさない" {
  setup_parents
  run_script status-set.sh --issue 17 --to Done
  assert_success
  assert_equal "$(called api-parent)" 0
  assert_equal "$(moved)" "IT17,"
  echo '{"project": {"owner": "me", "number": 4}, "status": {"pr_opened": "In Progress"}}' >"$REPO/.claude/dev-workflow/config.json"
  : >"$CALLS"
  run_script status-set.sh --issue 17 --to pr_opened
  assert_success
  assert_equal "$(called api-parent)" 0
  assert_equal "$(moved)" "IT17,"
}

@test "親の列を移せなくても、子の移動は止めずに警告する" {
  setup_parents
  FAKE_FAIL=SetField.2 FAKE_FAIL_MSG="gh: boom" run_script status-set.sh --issue 17 --to start
  assert_success
  assert_output --partial "親の Issue #10 の列を start に移せませんでした"
  assert_equal "$(json_of "$output" | jq -r '[.changed, .to] | join(",")')" "true,In Progress"
}

@test "親を読めなくても、子の移動は止めずに警告する" {
  setup_parents
  FAKE_FAIL=api-parent FAKE_FAIL_MSG="gh: boom" run_script status-set.sh --issue 17 --to start
  assert_success
  assert_output --partial "Issue #17 の親を読めなかったので、親の列は移しません"
  assert_equal "$(moved)" "IT17,"
}

@test "dry-run では親も移さず、予定に出す" {
  setup_parents
  run_script status-set.sh --issue 17 --to start --dry-run
  assert_success
  assert_equal "$(called SetField)" 0
  assert_equal "$(jq -c '[.actions[] | select(startswith("親の"))] | length' <<<"$output")" 2
}

@test "--no-parents では親を読まない" {
  setup_parents
  run_script status-set.sh --issue 17 --to start --no-parents
  assert_success
  assert_equal "$(called api-parent)" 0
}

@test "--only-from は、今の列が違えば何もせず、--item-id とは一緒に指定できない" {
  setup_parents
  run_script status-set.sh --issue 17 --to start --only-from Done
  assert_success
  assert_equal "$(jq -r .skipped <<<"$output")" true
  assert_equal "$(called SetField)" 0
  run_script status-set.sh --issue 17 --to start --only-from todo --item-id X
  assert_failure 64
}

# --- parent-state.sh ----------------------------------------------------------------

sub() { jq -nc --argjson n "$1" --arg s "$2" --arg r "${3:-}" '{number: $n, title: "子 \($n)", state: $s, state_reason: (if $r == "" then null else $r end)}'; }
set_children() { local p="$1"; shift; printf '%s\n' "$@" | jq -s . >"$FIX/sub-issues-$p.json"; }

@test "parent-state: 子がすべて閉じた親は all_closed で、completed を案にする" {
  setup_parents
  set_children 10 "$(sub 17 open)" "$(sub 18 closed completed)"
  set_children 5 "$(sub 10 open)"
  run_script parent-state.sh --issue 17 --assume-closed 17
  assert_success
  assert_equal "$(jq -c '.parents[0] | [.number, .state, .column, .children.total, .children.closed, .children.open, .all_closed, .suggest]' <<<"$output")" \
    '[10,"open","Todo",2,2,0,true,"completed"]'
  # 上の親は、下の親がまだ開いているので all_closed ではない
  assert_equal "$(jq -c '.parents[1] | [.number, .all_closed, .suggest]' <<<"$output")" '[5,false,null]'
}

@test "parent-state: 子がすべて取りやめなら not_planned を案にする。混ざっていれば completed" {
  setup_parents
  set_children 10 "$(sub 17 closed not_planned)" "$(sub 18 closed duplicate)"
  set_children 5 "$(sub 10 open)"
  run_script parent-state.sh --issue 17
  assert_success
  assert_equal "$(jq -r '.parents[0].suggest' <<<"$output")" not_planned
  set_children 10 "$(sub 17 closed not_planned)" "$(sub 18 closed completed)"
  run_script parent-state.sh --issue 17
  assert_equal "$(jq -r '.parents[0].suggest' <<<"$output")" completed
}

@test "parent-state: 開いている子があれば all_closed ではなく、閉じた親には案を出さない" {
  setup_parents
  set_parent 17 10 closed me/demo completed
  set_children 10 "$(sub 17 closed completed)"
  run_script parent-state.sh --issue 17
  assert_success
  assert_equal "$(jq -c '.parents | length' <<<"$output")" 2
  assert_equal "$(jq -c '.parents[0] | [.state, .all_closed, .suggest]' <<<"$output")" '["closed",true,null]'
  set_parent 17 10
  set_children 10 "$(sub 17 closed completed)" "$(sub 18 open)"
  run_script parent-state.sh --issue 17
  assert_equal "$(jq -c '.parents[0] | [.all_closed, .suggest, .children.open]' <<<"$output")" '[false,null,1]'
}

@test "parent-state: 親が無ければ空、別のリポジトリの親は含めない、Project が未設定なら column は null" {
  setup_fake_gh
  run_script parent-state.sh --issue 17
  assert_success
  assert_equal "$(jq -c .parents <<<"$output")" "[]"
  set_parent 17 10 open other/repo
  run_script parent-state.sh --issue 17
  assert_equal "$(jq -c .parents <<<"$output")" "[]"
  setup_parents
  echo '{}' >"$REPO/.claude/dev-workflow/config.json"
  set_children 10 "$(sub 17 open)"
  run_script parent-state.sh --issue 17
  assert_success
  assert_equal "$(jq -c '.parents[0].column' <<<"$output")" null
  assert_equal "$(called ProjectView)" 0
}
