#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper

# 偽の gh。GraphQL は操作名（query Foo / mutation Foo）ごとに $FIX/<操作名>.json を返し、
# gh api -X POST .../issues は $FIX/issue.json を返す。どちらも「<操作名> <変数または本文>」を $CALLS に記録する。
# FAKE_FAIL に指定した操作名は、FAKE_FAIL_MSG（既定: gh: failed）を出して失敗する。
setup_fake_gh() {
  FIX="$TMP/fix"
  CALLS="$TMP/calls"
  export FIX CALLS
  mkdir -p "$TMP/bin" "$FIX"
  : >"$CALLS"
  cat >"$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
q=.
for a in "$@"; do
  if [ "${prev:-}" = -q ]; then q="$a"; fi
  prev="$a"
done
case "$1 $2" in
  "repo view") echo '{"nameWithOwner": "me/demo"}' | jq -r "$q" ;;
  "api -X")
    echo "CreateIssue $(jq -c .)" >>"$CALLS"
    if [ "${FAKE_FAIL:-}" = CreateIssue ]; then echo 'gh: Validation Failed (HTTP 422)' >&2; exit 1; fi
    cat "$FIX/issue.json"
    ;;
  "api graphql")
    body="$(cat)"
    op="$(jq -r .query <<<"$body" | grep -oE '(query|mutation) [A-Za-z]+' | head -n 1 | cut -d' ' -f2)"
    echo "$op $(jq -c .variables <<<"$body")" >>"$CALLS"
    if [ "${FAKE_FAIL:-}" = "$op" ]; then echo "${FAKE_FAIL_MSG:-gh: failed}" >&2; exit 1; fi
    if [ -f "$FIX/$op.json" ]; then cat "$FIX/$op.json"; else echo '{"data": {}}'; fi
    ;;
esac
SH
  chmod +x "$TMP/bin/gh"
  export PATH="$TMP/bin:$PATH"

  echo '{"project": {"owner": "me", "number": 4}}' >.claude/workflow.json
  project_fields '[{"id": "O1", "name": "Todo"}, {"id": "O2", "name": "In Progress"}]' true
  created_issue feat
  echo '{"data": {"addProjectV2ItemById": {"item": {"id": "IT30"}}}}' >"$FIX/AddItem.json"
  echo '{"data": {"updateProjectV2ItemFieldValue": {"projectV2Item": {"id": "IT30"}}}}' >"$FIX/SetField.json"
}

# 作った Issue として返す応答。使い方: created_issue <付いたラベル>...
created_issue() {
  jq -n --args '{number: 30, html_url: "https://github.com/me/demo/issues/30", node_id: "I30",
    labels: ($ARGS.positional | map({name: .}))}' "$@" >"$FIX/issue.json"
}

# 使い方: project_fields <Status の選択肢> <Story Point の項目があるか>
project_fields() {
  jq -n --argjson opts "$1" --argjson sp "$2" '{data: {repositoryOwner: {projectV2: {
    id: "P4", number: 4, url: "https://github.com/users/me/projects/4",
    fields: {nodes: ([{id: "F1", name: "Status", dataType: "SINGLE_SELECT", options: $opts}]
      + (if $sp then [{id: "F2", name: "Story Point", dataType: "NUMBER"}] else [] end))}}}}}' \
    >"$FIX/ProjectFields.json"
}

run_create() {
  run "${TEST_BASH:-bash}" "$SCRIPTS/issue-create.sh" "$@"
  # bats は失敗したテストの標準出力だけを表示するので、原因を追えるよう出力を残す
  printf '%s\n' "$output"
  # 標準エラーの警告の後ろに出る JSON だけを取り出す
  # macOS の BSD sed は日本語を含む入力で失敗することがあるので、バイト列として扱わせる
  json="$(printf '%s\n' "$output" | LC_ALL=C sed -n '/^{/,$p')"
}

called() { grep -c "^$1 " "$CALLS" || true; }
# 使い方: args <操作名> [何回目か] → 記録した変数または本文の JSON
args() { grep "^$1 " "$CALLS" | sed -n "${2:-1}p" | cut -d' ' -f2-; }

# 変更を伴う呼び出しが1つも無いことを確かめる。あれば記録を表示して失敗する
assert_no_changes() {
  if grep -qE '^(CreateIssue|AddItem|SetField) ' "$CALLS"; then
    fail "$(printf '呼ばれないはずの操作が呼ばれました:\n%s' "$(cat "$CALLS")")"
  fi
}

@test "Issue を作り、type ラベルを付け、Project に追加して Todo にする" {
  setup_fake_gh
  printf '## 背景\n説明\n' >body.md
  run_create --title "ログインを追加する" --type feat --body-file body.md
  assert_success
  assert_equal "$(args CreateIssue)" '{"title":"ログインを追加する","body":"## 背景\n説明","labels":["feat"]}'
  assert_equal "$(args AddItem)" '{"p":"P4","c":"I30"}'
  assert_equal "$(called SetField)" 1
  assert_equal "$(args SetField | jq -c '[.i, .f, .v]')" '["IT30","F1",{"singleSelectOptionId":"O1"}]'
  assert_equal "$(jq -c '[.number, .url, .project.status, .project.story_point]' <<<"$json")" \
    '[30,"https://github.com/me/demo/issues/30","Todo",null]'
}

@test "本文は標準入力からも渡せる" {
  setup_fake_gh
  created_issue fix
  run_create --title t --type fix --body-file - <<<"本文"
  assert_success
  assert_equal "$(args CreateIssue | jq -r .body)" "本文"
}

@test "Story Point を指定すると、数値の項目に設定する" {
  setup_fake_gh
  run_create --title t --type feat --story-point 5
  assert_success
  assert_equal "$(called SetField)" 2
  assert_equal "$(args SetField 2 | jq -c '[.f, .v]')" '["F2",{"number":5}]'
  assert_equal "$(jq -r .project.story_point <<<"$json")" 5
}

@test "Story Point が整数でなければ、何も作らずに止まる" {
  setup_fake_gh
  for v in abc 0.5; do
    run_create --title t --type feat --story-point "$v"
    assert_failure 64
    assert_output --partial "--story-point には整数を指定してください: $v"
  done
  assert_no_changes
}

@test "Story Point の 21 と 34 は設定できるが、分割を勧める警告を出す" {
  setup_fake_gh
  for v in 21 34; do
    run_create --title t --type feat --story-point "$v"
    assert_success
    assert_output --partial "Story Point ${v} は大きいので、Issue を分割できないか検討してください"
    assert_equal "$(jq -r .project.story_point <<<"$json")" "$v"
  done
}

@test "Story Point の 13 以下では警告しない" {
  setup_fake_gh
  run_create --title t --type feat --story-point 13
  assert_success
  refute_output --partial "分割"
}

@test "type ラベルが付かなかったら（書き込み権限が無い）、Project に追加せずに伝える" {
  setup_fake_gh
  created_issue
  run_create --title t --type feat
  assert_failure 1
  assert_output --partial "Issue #30（https://github.com/me/demo/issues/30）は作りましたが、type ラベル「feat」を付けられませんでした"
  assert_equal "$(called AddItem)" 0
}

@test "type が labels.types に無ければ、何も作らずに止まる" {
  setup_fake_gh
  run_create --title t --type feature
  assert_failure 64
  assert_output --partial "type は labels.types のどれかにしてください"
  assert_no_changes
}

@test "Story Point がフィボナッチ数でない、または 34 より大きければ、何も作らずに止まる" {
  setup_fake_gh
  for v in 4 0 55; do
    run_create --title t --type feat --story-point "$v"
    assert_failure 64
    assert_output --partial "Story Point は 1 / 2 / 3 / 5 / 8 / 13 / 21 / 34 のどれかにしてください: $v"
  done
  assert_no_changes
}

@test "Project に Story Point の項目が無いのに指定されたら、何も作らずに止まる" {
  setup_fake_gh
  project_fields '[{"id": "O1", "name": "Todo"}]' false
  run_create --title t --type feat --story-point 3
  assert_failure 1
  assert_output --partial "Story Point の項目「Story Point」がありません"
  assert_no_changes
}

@test "todo の列が Status 列に無ければ、何も作らずに止まる" {
  setup_fake_gh
  echo '{"project": {"owner": "me", "number": 4}, "status": {"todo": "Backlog"}}' >.claude/workflow.json
  run_create --title t --type feat
  assert_failure 1
  assert_output --partial "todo の列「Backlog」が Status 列にありません"
  assert_no_changes
}

@test "Project が見つからなければ（API は NOT_FOUND のエラーを返す）、何も作らずに止まる" {
  setup_fake_gh
  FAKE_FAIL=ProjectFields FAKE_FAIL_MSG="GraphQL: Could not resolve to a ProjectV2 with the number 4." \
    run_create --title t --type feat
  assert_failure 1
  assert_output --partial "Project が見つかりません: me/4"
  assert_no_changes
}

@test "Project を読めない（スコープ不足など）ときは、見つからないとは言わずに GitHub の理由を伝える" {
  setup_fake_gh
  FAKE_FAIL=ProjectFields FAKE_FAIL_MSG="GraphQL: Your token has not been granted the required scopes (INSUFFICIENT_SCOPES)" \
    run_create --title t --type feat
  assert_failure 1
  assert_output --partial "GitHub の API に失敗しました: GraphQL: Your token has not been granted the required scopes"
  refute_output --partial "見つかりません"
  assert_no_changes
}

@test "project.number が未設定なら、Issue だけ作って警告する" {
  setup_fake_gh
  echo '{}' >.claude/workflow.json
  created_issue docs
  run_create --title t --type docs
  assert_success
  assert_output --partial "project.number が未設定なので"
  assert_equal "$(called CreateIssue)" 1
  assert_equal "$(called ProjectFields)" 0
  assert_equal "$(called AddItem)" 0
  assert_equal "$(jq -c .project <<<"$json")" null
}

@test "Issue を作った後に失敗したら、作った Issue の番号を伝える" {
  setup_fake_gh
  FAKE_FAIL=SetField run_create --title t --type feat
  assert_failure 1
  assert_output --partial "Issue #30（https://github.com/me/demo/issues/30）は作りましたが、Status を「Todo」にできませんでした"
}

@test "Issue を作れなければ止まる" {
  setup_fake_gh
  FAKE_FAIL=CreateIssue run_create --title t --type feat
  assert_failure 1
  assert_output --partial "Issue を作れませんでした"
  assert_equal "$(called AddItem)" 0
}

@test "--title と --type は必須" {
  setup_fake_gh
  run_create --type feat
  assert_failure 64
  assert_output --partial "--title は必須です"
  run_create --title t
  assert_failure 64
  assert_output --partial "--type は必須です"
}

@test "--help は使い方を表示する" {
  setup_fake_gh
  run_create --help
  assert_success
  assert_output --partial "--story-point"
  refute_output --partial "set -euo"
}
