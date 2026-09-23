#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper

# 偽の gh。GraphQL は操作名（query Foo / mutation Foo）ごとに $FIX/<操作名>.json を返し、
# 呼ばれた操作名と変数を $CALLS に1行ずつ記録する。
# gh repo view は、リポジトリを指定すれば repo.json、指定しなければ（今いるリポジトリ）here.json を返す。
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
  "repo view")
    case "${3:-}" in
      "" | -*) f=here.json ;;
      *) f=repo.json ;;
    esac
    [ -f "$FIX/$f" ] || f=repo.json
    jq -r "$q" "$FIX/$f"
    ;;
  "issue list") jq -r "$q" "$FIX/issues.json" ;;
  "api graphql")
    body="$(cat)"
    op="$(jq -r .query <<<"$body" | grep -oE '(query|mutation) [A-Za-z]+' | head -n 1 | cut -d' ' -f2)"
    echo "$op $(jq -c .variables <<<"$body")" >>"$CALLS"
    # 同じ操作の n 回目の呼び出しには <操作名>.<n>.json があればそれを返す（ページ送りのテスト用）
    n="$(grep -c "^$op " "$CALLS")"
    if [ -f "$FIX/$op.$n.json" ]; then cat "$FIX/$op.$n.json"
    elif [ -f "$FIX/$op.json" ]; then cat "$FIX/$op.json"
    else echo '{"data": {}}'; fi
    ;;
esac
SH
  chmod +x "$TMP/bin/gh"
  export PATH="$TMP/bin:$PATH"

  fix repo.json '{"id": "R1", "name": "demo", "nameWithOwner": "me/demo", "owner": {"login": "me"}}'
  fix issues.json '[{"number": 1}, {"number": 2}]'
  fix Owner.json '{"data": {"repositoryOwner": {"__typename": "User", "id": "U1"}}}'
  projects '[]'
  fix CreateProject.json '{"data": {"createProjectV2": {"projectV2": {"id": "P1", "number": 7, "title": "demo", "url": "https://example.com/p/7"}}}}'
  detail '["R1"]' '[{"id": "O1", "name": "Todo"}, {"id": "O2", "name": "In Progress"}, {"id": "O3", "name": "Done"}]' true
  issues '[{"id": "I1", "number": 1, "items": []}, {"id": "I2", "number": 2, "items": []}]'
  fix AddItem.json '{"data": {"addProjectV2ItemById": {"item": {"id": "IT1"}}}}'
}

fix() { printf '%s\n' "$2" >"$FIX/$1"; }

# 使い方: projects <Project の配列>（1ページ）
projects() {
  jq -n --argjson n "$1" '{data: {repositoryOwner: {projectsV2: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: $n}}}}' \
    >"$FIX/Projects.json"
}

# 使い方: detail <紐付け済みリポジトリの id の配列> <Status の選択肢> <自動追加が有効か>
detail() {
  jq -n --argjson repos "$1" --argjson opts "$2" --argjson auto "$3" '{data: {node: {
    repositories: {nodes: ($repos | map({id: .}))},
    fields: {nodes: [{id: "F1", name: "Status", dataType: "SINGLE_SELECT",
      options: ($opts | map(. + {color: "GRAY", description: ""}))}]},
    workflows: {nodes: [
      {name: "Auto-add to project", enabled: false},
      {name: "Auto-add to project", enabled: $auto},
      {name: "Item closed", enabled: true}]}}}}' \
    >"$FIX/ProjectDetail.json"
}

# 使い方: issues <[{id, number, items: [{id, project, status}]}]>（1ページ）
issues() {
  jq -n --argjson is "$1" '{data: {repository: {issues: {pageInfo: {hasNextPage: false, endCursor: null},
    nodes: ($is | map({id, number, projectItems: {nodes: (.items | map({id, project: {id: .project},
      fieldValueByName: (if .status then {name: .status} else null end)}))}}))}}}}' \
    >"$FIX/OpenIssues.json"
}

run_setup() {
  run "${TEST_BASH:-bash}" "$BATS_TEST_DIRNAME/../scripts/setup-project.sh" "$@"
  # bats は失敗したテストの標準出力だけを表示するので、原因を追えるよう出力を残す
  printf '%s\n' "$output"
  # 標準エラーの警告の後ろに出る JSON だけを取り出す
  # macOS の BSD sed は日本語を含む入力で失敗することがあるので、バイト列として扱わせる
  json="$(printf '%s\n' "$output" | LC_ALL=C sed -n '/^{/,$p')"
}

called() { grep -c "^$1 " "$CALLS" || true; }

@test "Project が無ければ作成し、Story Point を追加し、Issue を Todo にする" {
  setup_fake_gh
  run_setup
  assert_success
  assert_equal "$(called CreateProject)" 1
  assert_equal "$(called CreateNumberField)" 1
  assert_equal "$(called AddItem)" 2
  assert_equal "$(called SetStatus)" 2
  grep '^SetStatus ' "$CALLS" | grep -q '"o":"O1"'
  assert_equal "$(called LinkRepo)" 0
  assert_equal "$(called UpdateStatus)" 0
  assert_equal "$(jq -r '[.project.number, .project.created, .items.added, .items.set_todo] | join(",")' <<<"$json")" "7,true,2,2"
}

@test "dry-run では変更を伴う操作を呼ばず、紐付けを別の予定として出さない" {
  setup_fake_gh
  run_setup --dry-run
  assert_success
  assert_equal "$(grep -cE '^(Create|Link|Update|Add|Set)' "$CALLS" || true)" 0
  assert_equal "$(jq -r '.actions[0]' <<<"$json")" "Project「demo」を作成し、リポジトリ me/demo と紐付ける"
  assert_equal "$(jq '[.actions[] | select(startswith("リポジトリ"))] | length' <<<"$json")" 0
  assert_equal "$(jq -r '.actions[-1]' <<<"$json")" "オープンな Issue 2 件を追加し、「Todo」にする"
}

@test "同じ名前の Project があれば作らずに使う（名前は完全一致）" {
  setup_fake_gh
  projects '[{"id": "P8", "number": 8, "title": "demo-old", "url": "u", "closed": false},
    {"id": "P9", "number": 9, "title": "demo", "url": "u", "closed": false}]'
  run_setup
  assert_success
  assert_equal "$(called CreateProject)" 0
  assert_equal "$(jq -r '[.project.number, .project.created] | join(",")' <<<"$json")" "9,false"
}

@test "名前での探索は次のページまで見る" {
  setup_fake_gh
  jq -n '{data: {repositoryOwner: {projectsV2: {pageInfo: {hasNextPage: true, endCursor: "C1"},
    nodes: [{id: "P8", number: 8, title: "other", url: "u", closed: false}]}}}}' >"$FIX/Projects.1.json"
  jq -n '{data: {repositoryOwner: {projectsV2: {pageInfo: {hasNextPage: false, endCursor: null},
    nodes: [{id: "P9", number: 9, title: "demo", url: "u", closed: false}]}}}}' >"$FIX/Projects.2.json"
  run_setup
  assert_success
  assert_equal "$(called Projects)" 2
  grep '^Projects ' "$CALLS" | sed -n 2p | grep -q '"after":"C1"'
  assert_equal "$(called CreateProject)" 0
  assert_equal "$(jq -r .project.number <<<"$json")" 9
}

@test "--number で既存の Project に接続する" {
  setup_fake_gh
  fix ProjectByNumber.json '{"data": {"repositoryOwner": {"projectV2": {"id": "P3", "number": 3, "title": "x", "url": "u"}}}}'
  run_setup --number 3
  assert_success
  assert_equal "$(called Projects)" 0
  assert_equal "$(jq -r .project.number <<<"$json")" 3
}

@test "設定に project.number があれば、名前で探さずにその Project を使う" {
  setup_fake_gh
  echo '{"project": {"owner": "team", "number": 12}}' >.claude/workflow.json
  fix ProjectByNumber.json '{"data": {"repositoryOwner": {"projectV2": {"id": "P12", "number": 12, "title": "Team Board", "url": "u"}}}}'
  run_setup
  assert_success
  assert_equal "$(called Projects)" 0
  assert_equal "$(called CreateProject)" 0
  grep '^ProjectByNumber ' "$CALLS" | grep -q '"login":"team","number":12'
}

@test "足りない Status の列は、既存の選択肢の id を残したまま追加する" {
  setup_fake_gh
  detail '["R1"]' '[{"id": "O1", "name": "Todo"}, {"id": "O3", "name": "Done"}]' true
  run_setup
  assert_success
  assert_equal "$(called UpdateStatus)" 1
  opts="$(grep '^UpdateStatus ' "$CALLS" | cut -d' ' -f2- | jq -c '[.opts[] | [.id, .name]]')"
  assert_equal "$opts" '[["O1","Todo"],["O3","Done"],[null,"In Progress"]]'
}

@test "Project に入っている Issue は追加せず、Status が入っていれば変更もしない" {
  setup_fake_gh
  projects '[{"id": "P1", "number": 7, "title": "demo", "url": "u", "closed": false}]'
  issues '[{"id": "I1", "number": 1, "items": [{"id": "IT1", "project": "P1", "status": "In Progress"}]},
    {"id": "I2", "number": 2, "items": [{"id": "IT2", "project": "P1", "status": null}]},
    {"id": "I3", "number": 3, "items": [{"id": "ITX", "project": "OTHER", "status": "Todo"}]}]'
  run_setup
  assert_success
  assert_equal "$(called AddItem)" 1
  grep '^AddItem ' "$CALLS" | grep -q '"c":"I3"'
  assert_equal "$(called SetStatus)" 2
  grep '^SetStatus ' "$CALLS" | grep -q '"i":"IT2"'
  assert_equal "$(jq -r '[.items.added, .items.set_todo] | join(",")' <<<"$json")" "1,2"
}

@test "todo の列が無ければ警告し、Status を設定しない" {
  setup_fake_gh
  echo '{"status": {"todo": "Backlog"}}' >.claude/workflow.json
  detail '["R1"]' '[{"id": "O2", "name": "In Progress"}, {"id": "O3", "name": "Done"}]' true
  fix UpdateStatus.json '{"data": {}}'
  run_setup
  assert_success
  assert_output --partial "todo の列「Backlog」が Status 列に無い"
  assert_equal "$(called SetStatus)" 0
}

@test "リポジトリと未紐付けなら紐付ける" {
  setup_fake_gh
  projects '[{"id": "P1", "number": 7, "title": "demo", "url": "u", "closed": false}]'
  detail '[]' '[{"id": "O1", "name": "Todo"}, {"id": "O2", "name": "In Progress"}, {"id": "O3", "name": "Done"}]' true
  run_setup
  assert_equal "$(called LinkRepo)" 1
}

@test "自動追加はどれか1つが有効なら有効とみなす" {
  setup_fake_gh
  run_setup
  assert_equal "$(jq -r .workflows.auto_add <<<"$json")" true
  refute_output --partial "自動追加（Auto-add to project）が無効です"
}

@test "自動追加が無効なら警告し、設定画面の URL を返す（組織なら orgs）" {
  setup_fake_gh
  fix Owner.json '{"data": {"repositoryOwner": {"__typename": "Organization", "id": "G1"}}}'
  detail '["R1"]' '[{"id": "O1", "name": "Todo"}, {"id": "O2", "name": "In Progress"}, {"id": "O3", "name": "Done"}]' false
  run_setup
  assert_success
  assert_output --partial "自動追加（Auto-add to project）が無効です"
  assert_equal "$(jq -r .workflows.auto_add <<<"$json")" false
  assert_equal "$(jq -r .workflows.url <<<"$json")" "https://github.com/orgs/me/projects/7/workflows"
}

@test "作成の応答に projectV2 が無ければエラーで止まる" {
  setup_fake_gh
  fix CreateProject.json '{"data": {"createProjectV2": null}}'
  run_setup --write-config
  assert_failure 1
  assert_output --partial "Project を作成できませんでした"
  [ ! -f .claude/workflow.json ]
}

@test "--write-config は他の設定を残したまま project を書き込む" {
  setup_fake_gh
  echo '{"language": "en"}' >.claude/workflow.json
  run_setup --write-config
  assert_success
  assert_equal "$(jq -c . .claude/workflow.json)" '{"language":"en","project":{"owner":"me","number":7}}'
}

@test "--repo が今いるリポジトリと違うとき --write-config はエラーになる" {
  setup_fake_gh
  fix here.json '{"nameWithOwner": "me/here"}'
  run_setup --repo me/demo --write-config
  assert_failure 64
  assert_output --partial "対象のリポジトリ（me/demo）の中で実行してください"
}

@test "--number に数字以外を渡すとエラーになる" {
  setup_fake_gh
  run_setup --number abc
  assert_failure 64
}

@test "オプションの値が無ければ終了コード 64" {
  setup_fake_gh
  run_setup --number
  assert_failure 64
  assert_output --partial "--number に値がありません"
}
