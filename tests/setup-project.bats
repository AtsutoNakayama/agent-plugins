#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper

# 偽の gh。GraphQL は操作名（query Foo / mutation Foo）ごとに $FIX/<操作名>.json を返し、
# 呼ばれた操作名と変数を $CALLS に1行ずつ記録する。gh project と Project の REST・所有者（users/<login>）は
# fake_gh_project.bash が同じように受け持つ（Owner・Projects・ProjectView・CreateProject・LinkRepo・CreateNumberField・
# AddItem・SetField）。FAKE_FAIL に指定した操作名は、FAKE_FAIL_MSG（既定: gh: failed）を出して失敗する。
# gh repo view は、リポジトリを指定すれば repo.json、指定しなければ（今いるリポジトリ）here.json を返す。
setup_fake_gh() {
  FIX="$TMP/fix"
  CALLS="$TMP/calls"
  export FIX CALLS
  mkdir -p "$TMP/bin" "$FIX"
  : >"$CALLS"
  cat >"$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
# shellcheck source=/dev/null
. "$FAKE_GH_PROJECT"
fake_gh_project "$@"
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
    if [ "${FAKE_FAIL:-}" = "$op" ]; then echo "${FAKE_FAIL_MSG:-gh: failed}" >&2; exit 1; fi
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
  fix Owner.json '{"login": "me", "type": "User"}'
  projects '[]'
  fix CreateProject.json '{"id": "P1", "number": 7, "title": "demo", "url": "https://example.com/p/7", "closed": false}'
  detail '["R1"]' '[{"id": "O1", "name": "Todo"}, {"id": "O2", "name": "In Progress"}, {"id": "O3", "name": "Done"}]' true
  issues '[{"number": 1, "items": []}, {"number": 2, "items": []}]'
  fix AddItem.json '{"id": "IT1"}'
}

fix() { printf '%s\n' "$2" >"$FIX/$1"; }

# gh project list の応答。使い方: projects <Project の配列>
projects() {
  jq -n --argjson n "$1" '{projects: $n, totalCount: ($n | length)}' >"$FIX/Projects.json"
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

# 使い方: issues <[{number, items: [{id, project, status}]}]> [ファイル名] [次のページがあるか] [カーソル]
# 既定は1ページだけ（OpenIssues.json、次のページなし）。ページ送りのテストでは OpenIssues.<n>.json に書く
issues() {
  jq -n --argjson is "$1" --argjson next "${3:-false}" --argjson cursor "${4:-null}" \
    '{data: {repository: {issues: {pageInfo: {hasNextPage: $next, endCursor: $cursor},
    nodes: ($is | map({url: "https://github.com/me/demo/issues/\(.number)", number, projectItems: {nodes: (.items | map({id, project: {id: .project},
      fieldValueByName: (if .status then {name: .status} else null end)}))}}))}}}}' \
    >"$FIX/${2:-OpenIssues.json}"
}

run_setup() {
  run "${TEST_BASH:-bash}" "$SCRIPTS/setup/setup-project.sh" "$@"
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
  assert_equal "$(called SetField)" 2
  grep '^SetField ' "$CALLS" | grep -q '"single-select-option-id":"O1"'
  # 作成の直後に1回だけ紐付ける（作成後の詳細では紐付け済みなので、もう一度は紐付けない）
  assert_equal "$(called LinkRepo)" 1
  assert_equal "$(grep '^LinkRepo ' "$CALLS" | cut -d' ' -f2- | jq -c '[._[0], .owner, .repo]')" '["7","me","me/demo"]'
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

@test "名前での探索は、件数の上限を大きくして全件を読み、閉じた Project は使わない" {
  setup_fake_gh
  projects '[{"id": "P8", "number": 8, "title": "demo", "url": "u", "closed": true},
    {"id": "P9", "number": 9, "title": "demo", "url": "u", "closed": false}]'
  run_setup
  assert_success
  assert_equal "$(grep '^Projects ' "$CALLS" | cut -d' ' -f2- | jq -r '[.owner, .limit] | join(",")')" "me,10000"
  assert_equal "$(called CreateProject)" 0
  assert_equal "$(jq -r .project.number <<<"$json")" 9
}

@test "--number で既存の Project に接続する" {
  setup_fake_gh
  fix ProjectView.json '{"id": "P3", "number": 3, "title": "x", "url": "u", "owner": {"login": "me", "type": "User"}}'
  run_setup --number 3
  assert_success
  assert_equal "$(called Projects)" 0
  assert_equal "$(jq -r .project.number <<<"$json")" 3
}

@test "--number の Project が無ければ（gh は Could not resolve のエラーを返す）、案内して止まる" {
  setup_fake_gh
  FAKE_FAIL=ProjectView FAKE_FAIL_MSG="GraphQL: Could not resolve to a ProjectV2 with the number 99. (user.projectV2)" \
    run_setup --number 99
  assert_failure 1
  assert_output --partial "Project が見つかりません: me/99"
  assert_equal "$(called CreateProject)" 0
}

@test "--number の Project を読めない（スコープ不足など）ときは、GitHub の理由を伝える" {
  setup_fake_gh
  FAKE_FAIL=ProjectView FAKE_FAIL_MSG="GraphQL: INSUFFICIENT_SCOPES" run_setup --number 3
  assert_failure 1
  assert_output --partial "GitHub の API に失敗しました: GraphQL: INSUFFICIENT_SCOPES"
  refute_output --partial "見つかりません"
}

@test "設定に project.number があれば、名前で探さずにその Project を使う" {
  setup_fake_gh
  echo '{"project": {"owner": "team", "number": 12}}' >.claude/dev-workflow/config.json
  fix ProjectView.json '{"id": "P12", "number": 12, "title": "Team Board", "url": "u", "owner": {"login": "team", "type": "Organization"}}'
  run_setup
  assert_success
  assert_equal "$(called Projects)" 0
  assert_equal "$(called CreateProject)" 0
  assert_equal "$(grep '^ProjectView ' "$CALLS" | cut -d' ' -f2- | jq -c '[._[0], .owner]')" '["12","team"]'
}

@test "足りない Status の列は、既存の選択肢の id を残したまま、設定の順で前にある列の後ろに追加する" {
  setup_fake_gh
  detail '["R1"]' '[{"id": "O1", "name": "Todo"}, {"id": "O3", "name": "Done"}]' true
  run_setup
  assert_success
  assert_equal "$(called UpdateStatus)" 1
  opts="$(grep '^UpdateStatus ' "$CALLS" | cut -d' ' -f2- | jq -c '[.opts[] | [.id, .name]]')"
  assert_equal "$opts" '[["O1","Todo"],[null,"In Progress"],["O3","Done"]]'
}

@test "pr_opened の列は、start の列の後ろ（done の列の前）に追加し、利用者が足した列の位置は変えない" {
  setup_fake_gh
  echo '{"status": {"pr_opened": "In Review"}}' >.claude/dev-workflow/config.json
  detail '["R1"]' '[{"id": "O1", "name": "Todo"}, {"id": "OB", "name": "Blocked"}, {"id": "O2", "name": "In Progress"},
    {"id": "O3", "name": "Done"}, {"id": "OX", "name": "Archive"}]' true
  run_setup
  assert_success
  opts="$(grep '^UpdateStatus ' "$CALLS" | cut -d' ' -f2- | jq -c '[.opts[] | [.id, .name]]')"
  assert_equal "$opts" '[["O1","Todo"],["OB","Blocked"],["O2","In Progress"],[null,"In Review"],["O3","Done"],["OX","Archive"]]'
}

@test "保留の列（hold）が設定されていれば、todo の列の後ろ（start の列の前）に追加する" {
  setup_fake_gh
  echo '{"status": {"hold": "On Hold"}}' >.claude/dev-workflow/config.json
  run_setup
  assert_success
  opts="$(grep '^UpdateStatus ' "$CALLS" | cut -d' ' -f2- | jq -c '[.opts[] | [.id, .name]]')"
  assert_equal "$opts" '[["O1","Todo"],[null,"On Hold"],["O2","In Progress"],["O3","Done"]]'
}

@test "保留の列（hold）が既定（null）なら、Status 列を変えない" {
  setup_fake_gh
  run_setup
  assert_success
  assert_equal "$(called UpdateStatus)" 0
}

@test "役割の列名が空文字（hold や pr_opened）なら、未設定として Status 列に足さない" {
  setup_fake_gh
  echo '{"status": {"hold": "", "pr_opened": ""}}' >.claude/dev-workflow/config.json
  run_setup
  assert_success
  assert_equal "$(called UpdateStatus)" 0
}

@test "--hold-column は、設定に無くても保留の列を追加し、--write-config なら status.hold を書き込む" {
  setup_fake_gh
  echo '{"language": "en"}' >.claude/dev-workflow/config.json
  run_setup --hold-column "On Hold" --write-config
  assert_success
  opts="$(grep '^UpdateStatus ' "$CALLS" | cut -d' ' -f2- | jq -c '[.opts[] | [.id, .name]]')"
  assert_equal "$opts" '[["O1","Todo"],[null,"On Hold"],["O2","In Progress"],["O3","Done"]]'
  assert_equal "$(jq -c . .claude/dev-workflow/config.json)" \
    '{"language":"en","project":{"owner":"me","number":7},"status":{"hold":"On Hold"}}'
}

@test "--hold-column は、dry-run では設定を書かず、予定に出す" {
  setup_fake_gh
  echo '{"language": "en"}' >.claude/dev-workflow/config.json
  run_setup --hold-column "On Hold" --write-config --dry-run
  assert_success
  assert_equal "$(jq -c . .claude/dev-workflow/config.json)" '{"language":"en"}'
  assert_equal "$(jq '[.actions[] | select(contains("status.hold を「On Hold」にする"))] | length' <<<"$json")" 1
}

@test "--hold-column は、status.hold が同じならファイルを書き直さず、予定にも出さない" {
  setup_fake_gh
  printf '%s\n' '{"project":{"owner":"me","number":9},"status":{"hold":"On Hold"}}' >.claude/dev-workflow/config.json
  fix ProjectView.json '{"id": "P9", "number": 9, "title": "demo", "url": "u", "owner": {"login": "me", "type": "User"}}'
  run_setup --hold-column "On Hold" --write-config
  assert_success
  assert_equal "$(cat .claude/dev-workflow/config.json)" '{"project":{"owner":"me","number":9},"status":{"hold":"On Hold"}}'
  assert_equal "$(jq '[.actions[] | select(contains("config.json"))] | length' <<<"$json")" 0
}

@test "--hold-column で保留の列を別の名前に変えるとき、古い列に Issue が残っていれば、何も変えずに止まる" {
  setup_fake_gh
  printf '%s\n' '{"project":{"owner":"me","number":9},"status":{"hold":"On Hold"}}' >.claude/dev-workflow/config.json
  fix ProjectView.json '{"id": "P9", "number": 9, "title": "demo", "url": "u", "owner": {"login": "me", "type": "User"}}'
  detail '[]' '[{"id": "O1", "name": "Todo"}, {"id": "OH", "name": "On Hold"}, {"id": "O2", "name": "In Progress"},
    {"id": "O3", "name": "Done"}]' true
  issues '[{"number": 1, "items": [{"id": "IT1", "project": "P9", "status": "On Hold"}]},
    {"number": 2, "items": [{"id": "IT2", "project": "P9", "status": "Todo"}]},
    {"number": 3, "items": [{"id": "IT3", "project": "P9", "status": "On Hold"}]},
    {"number": 4, "items": []}]'
  for mode in --dry-run ""; do
    run_setup --hold-column Waiting --write-config ${mode:+"$mode"}
    assert_failure 2
    assert_output --partial "保留の列「On Hold」に Issue が残っています（#1・#3）。task-status で新しい列「Waiting」へ移してから、もう一度実行してください"
  done
  # Project の列も、リポジトリとの紐付けも、Issue も、設定も変えない
  assert_equal "$(grep -cE '^(Create|Link|Update|Add|Set)' "$CALLS" || true)" 0
  assert_equal "$(cat .claude/dev-workflow/config.json)" '{"project":{"owner":"me","number":9},"status":{"hold":"On Hold"}}'
}

@test "--hold-column で保留の列を別の名前に変えるとき、古い列にこのリポジトリの Issue が無ければ、新しい列を足して設定を書き換える" {
  setup_fake_gh
  printf '%s\n' '{"project":{"owner":"me","number":9},"status":{"hold":"On Hold"}}' >.claude/dev-workflow/config.json
  fix ProjectView.json '{"id": "P9", "number": 9, "title": "demo", "url": "u", "owner": {"login": "me", "type": "User"}}'
  detail '["R1"]' '[{"id": "O1", "name": "Todo"}, {"id": "OH", "name": "On Hold"}, {"id": "O2", "name": "In Progress"},
    {"id": "O3", "name": "Done"}]' true
  # ほかの Project で古い列名にある Issue は数えない
  issues '[{"number": 1, "items": [{"id": "IT1", "project": "P9", "status": "Todo"}, {"id": "ITX", "project": "OTHER", "status": "On Hold"}]}]'
  run_setup --hold-column Waiting --write-config
  assert_success
  opts="$(grep '^UpdateStatus ' "$CALLS" | cut -d' ' -f2- | jq -c '[.opts[] | [.id, .name]]')"
  # 新しい列は設定の順のとおり Todo の後ろに入り、古い列は利用者が足した列と同じく、位置を変えずに残す
  assert_equal "$opts" '[["O1","Todo"],[null,"Waiting"],["OH","On Hold"],["O2","In Progress"],["O3","Done"]]'
  assert_equal "$(jq -c .status .claude/dev-workflow/config.json)" '{"hold":"Waiting"}'
}

@test "保留の列がほかの役割の列と同じ名前なら、何も変えずに止まる" {
  setup_fake_gh
  run_setup --hold-column Todo --write-config
  assert_failure 2
  assert_output --partial "保留の列（status.hold）は、ほかの役割（status.todo）と別の列名にしてください: Todo"
  assert_equal "$(called CreateProject)" 0
  [ ! -f .claude/dev-workflow/config.json ]
}

@test "設定の順で前にある列が1つも無ければ、後ろにある列の前に追加する" {
  setup_fake_gh
  detail '["R1"]' '[{"id": "OX", "name": "Archive"}, {"id": "O3", "name": "Done"}]' true
  run_setup
  assert_success
  opts="$(grep '^UpdateStatus ' "$CALLS" | cut -d' ' -f2- | jq -c '[.opts[] | [.id, .name]]')"
  assert_equal "$opts" '[["OX","Archive"],[null,"Todo"],[null,"In Progress"],["O3","Done"]]'
}

@test "Project に入っている Issue は追加せず、Status が入っていれば変更もしない" {
  setup_fake_gh
  projects '[{"id": "P1", "number": 7, "title": "demo", "url": "u", "closed": false}]'
  issues '[{"number": 1, "items": [{"id": "IT1", "project": "P1", "status": "In Progress"}]},
    {"number": 2, "items": [{"id": "IT2", "project": "P1", "status": null}]},
    {"number": 3, "items": [{"id": "ITX", "project": "OTHER", "status": "Todo"}]}]'
  run_setup
  assert_success
  assert_equal "$(called AddItem)" 1
  grep '^AddItem ' "$CALLS" | grep -q '"url":"https://github.com/me/demo/issues/3"'
  assert_equal "$(called SetField)" 2
  grep '^SetField ' "$CALLS" | grep -q '"id":"IT2"'
  assert_equal "$(jq -r '[.items.added, .items.set_todo] | join(",")' <<<"$json")" "1,2"
}

@test "オープンな Issue は、カーソルで次のページを読み、全ページの Issue を Project に入れる" {
  setup_fake_gh
  projects '[{"id": "P1", "number": 7, "title": "demo", "url": "u", "closed": false}]'
  issues '[{"number": 1, "items": []}]' OpenIssues.1.json true '"C1"'
  issues '[{"number": 2, "items": []}]' OpenIssues.2.json
  run_setup
  assert_success
  assert_equal "$(called OpenIssues)" 2
  assert_equal "$(grep '^OpenIssues ' "$CALLS" | sed -n 2p | cut -d' ' -f2- | jq -r .after)" C1
  assert_equal "$(called AddItem)" 2
}

@test "オープンな Issue のページ送りのカーソルが null なら、同じページを読み続けずに止まる" {
  setup_fake_gh
  projects '[{"id": "P1", "number": 7, "title": "demo", "url": "u", "closed": false}]'
  issues '[{"number": 1, "items": []}]' OpenIssues.1.json true null
  # 止まらずに次を読んだときに、テストが終わらなくならないよう、最後のページを置く
  issues '[{"number": 2, "items": []}]' OpenIssues.2.json
  run_setup
  assert_failure 1
  assert_output --partial "オープンな Issue のページ送りが進みません: me/demo"
  assert_equal "$(called OpenIssues)" 1
  assert_equal "$(called AddItem)" 0
}

@test "オープンな Issue のページ送りのカーソルが前回と同じなら、同じページを読み続けずに止まる" {
  setup_fake_gh
  projects '[{"id": "P1", "number": 7, "title": "demo", "url": "u", "closed": false}]'
  issues '[{"number": 1, "items": []}]' OpenIssues.1.json true '"C1"'
  issues '[{"number": 2, "items": []}]' OpenIssues.2.json true '"C1"'
  issues '[{"number": 3, "items": []}]' OpenIssues.3.json
  run_setup
  assert_failure 1
  assert_output --partial "オープンな Issue のページ送りが進みません: me/demo"
  assert_equal "$(called OpenIssues)" 2
  assert_equal "$(called AddItem)" 0
}

@test "todo の列が無ければ警告し、Status を設定しない" {
  setup_fake_gh
  echo '{"status": {"todo": "Backlog"}}' >.claude/dev-workflow/config.json
  detail '["R1"]' '[{"id": "O2", "name": "In Progress"}, {"id": "O3", "name": "Done"}]' true
  fix UpdateStatus.json '{"data": {}}'
  run_setup
  assert_success
  assert_output --partial "todo の列「Backlog」が Status 列に無い"
  assert_equal "$(called SetField)" 0
}

@test "リポジトリと未紐付けなら紐付ける" {
  setup_fake_gh
  projects '[{"id": "P1", "number": 7, "title": "demo", "url": "u", "closed": false}]'
  detail '[]' '[{"id": "O1", "name": "Todo"}, {"id": "O2", "name": "In Progress"}, {"id": "O3", "name": "Done"}]' true
  run_setup
  assert_equal "$(called LinkRepo)" 1
  assert_equal "$(grep '^LinkRepo ' "$CALLS" | cut -d' ' -f2- | jq -c '[._[0], .owner, .repo]')" '["7","me","me/demo"]'
}

@test "所有者が見つからなければ止まる" {
  setup_fake_gh
  FAKE_FAIL=Owner FAKE_FAIL_MSG="gh: Not Found (HTTP 404)" run_setup
  assert_failure 1
  assert_output --partial "所有者が見つかりません: me"
  assert_equal "$(called CreateProject)" 0
}

@test "自動追加はどれか1つが有効なら有効とみなす" {
  setup_fake_gh
  run_setup
  assert_equal "$(jq -r .workflows.auto_add <<<"$json")" true
  refute_output --partial "自動追加（Auto-add to project）が無効です"
}

@test "自動追加が無効なら警告し、設定画面の URL を返す（組織なら orgs）" {
  setup_fake_gh
  fix Owner.json '{"login": "me", "type": "Organization"}'
  detail '["R1"]' '[{"id": "O1", "name": "Todo"}, {"id": "O2", "name": "In Progress"}, {"id": "O3", "name": "Done"}]' false
  run_setup
  assert_success
  assert_output --partial "自動追加（Auto-add to project）が無効です"
  assert_equal "$(jq -r .workflows.auto_add <<<"$json")" false
  assert_equal "$(jq -r .workflows.url <<<"$json")" "https://github.com/orgs/me/projects/7/workflows"
}

@test "作成した後に紐付けられなければ、Project を作ったことと再実行で紐付くことを伝えて止まる" {
  setup_fake_gh
  FAKE_FAIL=LinkRepo run_setup --write-config
  assert_failure 1
  assert_output --partial "Project「demo」（#7）は作りましたが、リポジトリ me/demo と紐付けられませんでした（もう一度実行すると紐付けます）"
  assert_equal "$(called CreateProject)" 1
  [ ! -f .claude/dev-workflow/config.json ]
}

@test "作成の応答に id が無ければエラーで止まる" {
  setup_fake_gh
  fix CreateProject.json '{}'
  run_setup --write-config
  assert_failure 1
  assert_output --partial "Project を作成できませんでした"
  [ ! -f .claude/dev-workflow/config.json ]
}

@test "--write-config は他の設定を残したまま project を書き込む" {
  setup_fake_gh
  echo '{"language": "en"}' >.claude/dev-workflow/config.json
  run_setup --write-config
  assert_success
  assert_equal "$(jq -c . .claude/dev-workflow/config.json)" '{"language":"en","project":{"owner":"me","number":7}}'
}

@test "--write-config は、.claude/dev-workflow/ が無ければ作って書き込む" {
  setup_fake_gh
  rm -rf .claude
  run_setup --write-config
  assert_success
  assert_equal "$(jq -c . .claude/dev-workflow/config.json)" '{"project":{"owner":"me","number":7}}'
}

@test "--write-config は、project が同じならファイルを書き直さず、予定にも出さない" {
  setup_fake_gh
  printf '%s\n' '{"project":{"owner":"me","number":9},"language":"ja"}' >.claude/dev-workflow/config.json
  fix ProjectView.json '{"id": "P9", "number": 9, "title": "demo", "url": "u", "owner": {"login": "me", "type": "User"}}'
  run_setup --write-config
  assert_success
  assert_equal "$(cat .claude/dev-workflow/config.json)" '{"project":{"owner":"me","number":9},"language":"ja"}'
  assert_equal "$(jq '[.actions[] | select(contains("config.json"))] | length' <<<"$json")" 0
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

@test "ホームのリポジトリでは、--write-config は GitHub に何も作らず、ユーザーの層のファイルにも書かずに止まる" {
  setup_fake_gh
  make_home_repo
  echo '{"language": "en"}' >"$WORKFLOW_USER_DIR/config.json"
  run_setup --write-config
  assert_failure 2
  assert_output --partial "ホームのリポジトリ"
  assert_equal "$(cat "$CALLS")" ""
  assert_equal "$(jq -c . "$WORKFLOW_USER_DIR/config.json")" '{"language":"en"}'
}
