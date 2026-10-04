#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper

# 偽の gh。
# - gh repo view ... -q .nameWithOwner            me/demo を返す
# - gh api graphql                                 「TodoItems <変数>」を $CALLS に記録し、$FIX/TodoItems.<n>.json（n 回目。無ければ TodoItems.json）を返す
# - gh api --paginate .../issues/<番号>/dependencies/blocked_by...  $FIX/blocked-<番号>.json（無ければ []）を返す
# - gh api repos/me/demo/issues/<番号> -q .state   $FIX/state-<番号>（無ければ closed）を返す。「GetIssue <番号>」を記録する
# - gh pr list ...                                 $FIX/pr-list.json（無ければ []）を返す
# FAKE_FAIL に指定した操作名（TodoItems・GetIssue・PrList）は、FAKE_FAIL_MSG（既定: gh: failed）を出して失敗する。
setup_fake_gh() {
  FIX="$TMP/fix"
  CALLS="$TMP/calls"
  export FIX CALLS
  mkdir -p "$TMP/bin" "$FIX"
  : >"$CALLS"
  : >"$FIX/nodes"
  cat >"$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
fail() { if [ "${FAKE_FAIL:-}" = "$1" ]; then echo "${FAKE_FAIL_MSG:-gh: failed}" >&2; exit 1; fi; }
case "$1 $2" in
  "repo view") echo me/demo ;;
  "api graphql")
    body="$(cat)"
    echo "TodoItems $(jq -c .variables <<<"$body")" >>"$CALLS"
    echo "$(jq -r .query <<<"$body")" >"$FIX/last-query"
    fail TodoItems
    n="$(grep -c '^TodoItems ' "$CALLS")"
    if [ -f "$FIX/TodoItems.$n.json" ]; then cat "$FIX/TodoItems.$n.json"; else cat "$FIX/TodoItems.json"; fi
    ;;
  "api --paginate")
    n="${3#*/issues/}"
    n="${n%%/*}"
    if [ -f "$FIX/blocked-$n.json" ]; then cat "$FIX/blocked-$n.json"; else echo '[]'; fi
    ;;
  "api repos/me/demo/issues/"*)
    n="${2##*/}"
    echo "GetIssue $n" >>"$CALLS"
    fail GetIssue
    if [ -f "$FIX/state-$n" ]; then cat "$FIX/state-$n"; else echo closed; fi
    ;;
  "pr list")
    fail PrList
    if [ -f "$FIX/pr-list.json" ]; then cat "$FIX/pr-list.json"; else echo '[]'; fi
    ;;
  *) echo "gh: 想定外の呼び出し: $*" >&2; exit 1 ;;
esac
SH
  chmod +x "$TMP/bin/gh"
  export PATH="$TMP/bin:$PATH"
  echo '{"project": {"owner": "me", "number": 4}}' >"$REPO/.claude/dev-workflow/config.json"
  write_page
}

# 使い方: item <番号> <列> [本文] [Story Point] [リポジトリ] [状態]
# Project の項目を、並びの末尾に足す（write_page で GraphQL の応答にする）
item() {
  jq -nc --argjson n "$1" --arg s "$2" --arg b "${3:-}" --arg sp "${4:-}" --arg r "${5:-me/demo}" --arg st "${6:-OPEN}" '{
    content: {__typename: "Issue", number: $n, title: "作業 \($n)", state: $st, body: $b,
      url: "https://github.com/me/demo/issues/\($n)", repository: {nameWithOwner: $r}},
    status: {name: $s}, sp: (if $sp == "" then null else {number: ($sp | tonumber)} end)}' >>"$FIX/nodes"
}

# 足した項目を、1ページ分の応答にする。使い方: write_page [ファイル名（既定 TodoItems.json）] [次のページがあるか]
write_page() {
  jq -sc --argjson next "${2:-false}" '{data: {repositoryOwner: {projectV2: {items: {
    pageInfo: {hasNextPage: $next, endCursor: "C1"}, nodes: .}}}}}' "$FIX/nodes" >"$FIX/${1:-TodoItems.json}"
  : >"$FIX/nodes"
}

# 使い方: out_of <jq の式>
out_of() { jq -c "$1" <<<"$output"; }

@test "Todo の Issue を Project の並び順に返し、先頭を次に着手するものにする" {
  setup_fake_gh
  item 30 Todo "" 3
  item 10 Todo
  item 20 Todo
  write_page
  run_script next-tasks.sh
  assert_success
  assert_equal "$(out_of '[.todo[] | [.number, .position]]')" '[[30,1],[10,2],[20,3]]'
  assert_equal "$(out_of .next)" 30
  assert_equal "$(out_of '.todo[0].story_point')" 3
}

@test "並びは GraphQL の POSITION で読む（呼び出しの変数に所有者・番号・Story Point の項目名を渡す）" {
  setup_fake_gh
  item 10 Todo
  write_page
  run_script next-tasks.sh
  assert_success
  grep -q 'orderBy: {field: POSITION, direction: ASC}' "$FIX/last-query"
  assert_equal "$(grep '^TodoItems ' "$CALLS" | cut -d' ' -f2-)" '{"owner":"me","number":4,"sp":"Story Point"}'
}

@test "Todo 以外の列・閉じた Issue・ほかのリポジトリの項目は含めない" {
  setup_fake_gh
  item 1 Done
  item 2 Todo "" "" me/other
  item 3 Todo "" "" me/demo CLOSED
  item 4 Todo
  write_page
  run_script next-tasks.sh
  assert_success
  assert_equal "$(out_of '[.todo[].number]')" '[4]'
}

@test "GitHub の依存関係（blocked by）が開いていれば待ちにして、次の候補に入れない" {
  setup_fake_gh
  item 10 Todo
  item 11 Todo
  write_page
  echo '[{"number": 5, "state": "open"}]' >"$FIX/blocked-10.json"
  echo open >"$FIX/state-5"
  run_script next-tasks.sh
  assert_success
  assert_equal "$(out_of '.todo[0] | [.number, .waiting, .blocked_by[0].number, .blocked_by[0].sources[0]]')" '[10,true,5,"dependency"]'
  assert_equal "$(out_of .next)" 11
  assert_equal "$(out_of '.parallel')" '[11]'
}

@test "依存先が閉じていれば待たない" {
  setup_fake_gh
  item 10 Todo
  write_page
  echo '[{"number": 5, "state": "closed"}]' >"$FIX/blocked-10.json"
  run_script next-tasks.sh
  assert_success
  assert_equal "$(out_of '.todo[0].waiting')" false
  assert_equal "$(out_of .next)" 10
}

@test "本文の「依存」の #N が開いていれば待ちにする（見出しの外の #N は見ない）" {
  setup_fake_gh
  item 10 Todo $'## 背景\n#99 のあと\n\n## 依存\n- #5\n- #6\n\n## 完了条件\n- #98'
  write_page
  echo open >"$FIX/state-5"
  echo closed >"$FIX/state-6"
  run_script next-tasks.sh
  assert_success
  assert_equal "$(out_of '.todo[0] | [.waiting, [.blocked_by[] | [.number, .sources[0]]]]')" '[true,[[5,"body"]]]'
  assert_equal "$(called GetIssue)" 2
}

@test "依存先が Todo や着手中の Issue なら、状態を読まずに待ちにする" {
  setup_fake_gh
  item 10 Todo $'## 依存\n- #11'
  item 11 Todo
  item 12 "In Progress"
  item 13 Todo $'## 依存\n- #12'
  write_page
  run_script next-tasks.sh
  assert_success
  assert_equal "$(called GetIssue)" 0
  assert_equal "$(out_of '[.todo[] | [.number, .waiting]]')" '[[10,true],[11,false],[13,true]]'
}

@test "同じ依存が blocked by と本文の両方にあれば1つにまとめる" {
  setup_fake_gh
  item 10 Todo $'## 依存\n- #5'
  write_page
  echo '[{"number": 5, "state": "open"}]' >"$FIX/blocked-10.json"
  echo open >"$FIX/state-5"
  run_script next-tasks.sh
  assert_success
  assert_equal "$(out_of '.todo[0].blocked_by')" '[{"repo":"me/demo","number":5,"sources":["body","dependency"],"state":"open"}]'
  # 状態は依存関係の API が返すので、REST で読み直さない
  assert_equal "$(called GetIssue)" 0
}

@test "領域が重ならない Issue は、次に着手するものと並列にできる組に入れる" {
  setup_fake_gh
  item 10 Todo $'## 変更するファイル・領域\n- `plugins/dev-workflow/scripts/next-tasks.sh`\n- docs/design.md'
  item 11 Todo $'## 変更するファイル・領域\n- tests/'
  write_page
  run_script next-tasks.sh
  assert_success
  assert_equal "$(out_of .parallel)" '[10,11]'
  assert_equal "$(out_of '.todo[1] | [.parallel, .reason]')" '[true,"領域が重ならない"]'
  assert_equal "$(out_of '.todo[0].areas')" '["docs/design.md","plugins/dev-workflow/scripts/next-tasks.sh"]'
}

@test "領域が重なる Issue（ディレクトリとその中のファイル。末尾の / は無視する）は並列にできないと印を付け、重なる相手とパスを添える" {
  setup_fake_gh
  item 10 Todo $'## 変更するファイル・領域\n- plugins/dev-workflow/scripts/'
  item 11 Todo $'## 変更するファイル・領域\n- plugins/dev-workflow/scripts/status-set.sh\n- docs/'
  item 12 Todo $'## 変更するファイル・領域\n- tests/'
  write_page
  run_script next-tasks.sh
  assert_success
  assert_equal "$(out_of .parallel)" '[10,12]'
  assert_equal "$(out_of '.todo[1] | [.parallel, .reason, .overlaps]')" \
    '[false,"選んだものと領域が重なる",[{"issue":10,"paths":[{"a":"plugins/dev-workflow/scripts/status-set.sh","b":"plugins/dev-workflow/scripts"}]}]]'
}

@test "名前が前方一致するだけのパスは重ならない（scripts と scripts-extra）" {
  setup_fake_gh
  item 10 Todo $'## 変更するファイル・領域\n- scripts'
  item 11 Todo $'## 変更するファイル・領域\n- scripts-extra'
  write_page
  run_script next-tasks.sh
  assert_success
  assert_equal "$(out_of .parallel)" '[10,11]'
}

@test "領域が不明（欄が無い・「不明」・空）の Issue は、並列にできる組に入れない" {
  setup_fake_gh
  item 10 Todo $'## 変更するファイル・領域\n- docs/'
  item 11 Todo
  item 12 Todo $'## 変更するファイル・領域\n- 不明'
  item 13 Todo $'## 変更するファイル・領域\n- \n\n## 依存\n- なし'
  write_page
  run_script next-tasks.sh
  assert_success
  assert_equal "$(out_of .parallel)" '[10]'
  assert_equal "$(out_of '[.todo[1:][] | [.area_known, .parallel, .reason]] | unique')" '[[false,false,"領域が不明なので、重なるか分からない"]]'
}

@test "次に着手するものの領域が不明なら、重なるか分からないので、ほかは並列にしない（次の1つは選ぶ）" {
  setup_fake_gh
  item 10 Todo
  item 11 Todo $'## 変更するファイル・領域\n- docs/'
  write_page
  run_script next-tasks.sh
  assert_success
  assert_equal "$(out_of .next)" 10
  assert_equal "$(out_of .parallel)" '[10]'
}

@test "待ちの Issue は、並列にできる組を決めるときに飛ばす（待ちの Issue の領域は見ない）" {
  setup_fake_gh
  item 10 Todo $'## 変更するファイル・領域\n- docs/'
  item 11 Todo $'## 変更するファイル・領域\n- docs/\n\n## 依存\n- #5'
  item 12 Todo $'## 変更するファイル・領域\n- tests/'
  write_page
  echo open >"$FIX/state-5"
  run_script next-tasks.sh
  assert_success
  assert_equal "$(out_of .parallel)" '[10,12]'
  assert_equal "$(out_of '.todo[1] | [.waiting, .parallel, .reason]')" '[true,false,"待ち（依存が終わっていない）"]'
}

@test "着手中の Issue の開いている PR が変えているファイルと重なれば、警告して並列にしない" {
  setup_fake_gh
  item 10 Todo $'## 変更するファイル・領域\n- plugins/dev-workflow/scripts/'
  item 11 Todo $'## 変更するファイル・領域\n- docs/'
  item 20 "In Progress"
  write_page
  cat >"$FIX/pr-list.json" <<'JSON'
[{"number": 50, "headRefName": "feat/20-something", "closingIssuesReferences": [],
  "files": [{"path": "plugins/dev-workflow/scripts/status-set.sh"}]},
 {"number": 51, "headRefName": "feat/999-other", "closingIssuesReferences": [], "files": [{"path": "docs/design.md"}]}]
JSON
  run_script next-tasks.sh
  assert_success
  assert_equal "$(out_of '.todo[0] | .conflicts_with_active')" '[{"issue":20,"paths":[{"a":"plugins/dev-workflow/scripts","b":"plugins/dev-workflow/scripts/status-set.sh"}]}]'
  assert_equal "$(out_of '.todo[0] | [.parallel, .reason]')" '[true,"次に着手する"]'
  assert_equal "$(out_of .parallel)" '[10,11]'
  assert_equal "$(out_of '.in_progress[0] | [.number, .pr_files]')" '[20,["plugins/dev-workflow/scripts/status-set.sh"]]'
}

@test "着手中の PR と重なる Issue は、次に着手するものでなければ並列の組に入れない" {
  setup_fake_gh
  item 10 Todo $'## 変更するファイル・領域\n- tests/'
  item 11 Todo $'## 変更するファイル・領域\n- docs/'
  item 20 "In Progress" $'## 変更するファイル・領域\n- docs/design.md'
  write_page
  run_script next-tasks.sh
  assert_success
  assert_equal "$(out_of .parallel)" '[10]'
  assert_equal "$(out_of '.todo[1] | [.parallel, .reason]')" '[false,"着手中のものと領域が重なる"]'
}

@test "PR は Closes で参照する Issue にも結び付ける" {
  setup_fake_gh
  item 10 Todo $'## 変更するファイル・領域\n- docs/'
  item 20 "In Progress"
  write_page
  echo '[{"number": 50, "headRefName": "topic", "closingIssuesReferences": [{"number": 20}], "files": [{"path": "docs/a.md"}]}]' >"$FIX/pr-list.json"
  run_script next-tasks.sh
  assert_success
  assert_equal "$(out_of '.todo[0].conflicts_with_active[0].issue')" 20
}

@test "Project の項目が複数のページにまたがっても、全部読む" {
  setup_fake_gh
  item 10 Todo
  write_page TodoItems.1.json true
  item 11 Todo
  write_page TodoItems.2.json false
  run_script next-tasks.sh
  assert_success
  assert_equal "$(out_of '[.todo[].number]')" '[10,11]'
  assert_equal "$(called TodoItems)" 2
  assert_equal "$(args TodoItems 2)" '{"owner":"me","number":4,"sp":"Story Point","after":"C1"}'
}

@test "別のリポジトリの依存先と番号が同じでも、状態を取り違えない（リポジトリと番号で区別する）" {
  setup_fake_gh
  item 10 Todo $'## 依存\n- #5'
  write_page
  # 別のリポジトリの #5 は閉じている。このリポジトリの #5（本文の依存）は開いている
  echo '[{"number": 5, "state": "closed", "repository_url": "https://api.github.com/repos/me/other"}]' >"$FIX/blocked-10.json"
  echo open >"$FIX/state-5"
  run_script next-tasks.sh
  assert_success
  assert_equal "$(out_of '.todo[0] | [.waiting, [.blocked_by[] | [.repo, .number]]]')" '[true,[["me/demo",5]]]'
  # 別のリポジトリの依存先が開いていれば、それも待ちの理由になる
  echo '[{"number": 5, "state": "open", "repository_url": "https://api.github.com/repos/me/other"}]' >"$FIX/blocked-10.json"
  echo closed >"$FIX/state-5"
  run_script next-tasks.sh
  assert_success
  assert_equal "$(out_of '.todo[0] | [.waiting, [.blocked_by[] | [.repo, .number]]]')" '[true,[["me/other",5]]]'
}

@test "着手中の Issue に PR も領域も無ければ、Todo の各 Issue に、重なるか分からないと警告を付ける" {
  setup_fake_gh
  item 10 Todo $'## 変更するファイル・領域\n- docs/'
  item 20 "In Progress"
  item 21 "In Progress" $'## 変更するファイル・領域\n- tests/'
  write_page
  run_script next-tasks.sh
  assert_success
  assert_equal "$(out_of .active_unknown)" '[20]'
  assert_equal "$(out_of '.todo[0].warnings')" '["着手中の #20 は PR も領域も無く、重なるか分からない"]'
  assert_equal "$(out_of '[.in_progress[] | [.number, .area_known]]')" '[[20,false],[21,true]]'
}

@test "着手中の Issue に領域か PR があれば、警告は付かない" {
  setup_fake_gh
  item 10 Todo $'## 変更するファイル・領域\n- docs/'
  item 20 "In Progress"
  write_page
  echo '[{"number": 50, "headRefName": "feat/20-x", "closingIssuesReferences": [], "files": [{"path": "tests/a.bats"}]}]' >"$FIX/pr-list.json"
  run_script next-tasks.sh
  assert_success
  assert_equal "$(out_of '[.active_unknown, .todo[0].warnings]')" '[[],[]]'
}

@test "「不明（理由）」のように不明・なしで始まる行は、領域として数えない" {
  setup_fake_gh
  item 10 Todo $'## 変更するファイル・領域\n- 不明（まだ決まっていません）\n- なし'
  write_page
  run_script next-tasks.sh
  assert_success
  assert_equal "$(out_of '.todo[0] | [.areas, .areas_ignored, .area_known]')" '[[],[],false]'
}

@test "パスと判断できない行（日本語の文・途中のグロブ）は領域に入れず、areas_ignored に出す" {
  setup_fake_gh
  item 10 Todo $'## 変更するファイル・領域\n- docs/\n- 以下のファイル、全部\n- plugins/*/scripts/a.sh'
  write_page
  run_script next-tasks.sh
  assert_success
  assert_equal "$(out_of '.todo[0] | [.areas, .areas_ignored]')" '[["docs"],["plugins/*/scripts/a.sh","以下のファイル、全部"]]'
}

@test "末尾の /** と /* は外してディレクトリとして扱い、「.」はリポジトリ全体と重なる" {
  setup_fake_gh
  item 10 Todo $'## 変更するファイル・領域\n- plugins/**\n- docs/*'
  item 11 Todo $'## 変更するファイル・領域\n- plugins/dev-workflow/scripts/status-set.sh'
  item 12 Todo $'## 変更するファイル・領域\n- `.`'
  write_page
  run_script next-tasks.sh
  assert_success
  assert_equal "$(out_of '.todo[0].areas')" '["docs","plugins"]'
  assert_equal "$(out_of '[.todo[1:][] | [.number, .parallel]]')" '[[11,false],[12,false]]'
  assert_equal "$(out_of '.todo[2].overlaps | length')" 1
}

@test "Todo が無ければ next は null" {
  setup_fake_gh
  item 1 Done
  write_page
  run_script next-tasks.sh
  assert_success
  assert_equal "$(out_of '[.next, .parallel, .todo]')" '[null,[],[]]'
}

@test "何も変えない（読む呼び出しだけ）" {
  setup_fake_gh
  item 10 Todo
  write_page
  run_script next-tasks.sh
  assert_success
  assert_equal "$(grep -vcE '^(TodoItems|GetIssue) ' "$CALLS")" 0
}

@test "project.number が未設定ならエラーになる" {
  setup_fake_gh
  echo '{}' >"$REPO/.claude/dev-workflow/config.json"
  run_script next-tasks.sh
  assert_failure 2
  assert_output --partial "project.number が未設定です"
}

@test "Project が無ければ案内して止まる" {
  setup_fake_gh
  echo '{"data": {"repositoryOwner": {"projectV2": null}}}' >"$FIX/TodoItems.json"
  run_script next-tasks.sh
  assert_failure 1
  assert_output --partial "Project が見つかりません: me/4"
}

@test "Project を読めないとき（認証・スコープ不足など）は、GitHub の理由を伝えて止まる" {
  setup_fake_gh
  FAKE_FAIL=TodoItems run_script next-tasks.sh
  assert_failure 1
  assert_output --partial "GitHub の API に失敗しました: gh: failed"
}

@test "所有者が無い（GraphQL が NOT_FOUND を返す）ときも、Project が見つからないと案内する" {
  setup_fake_gh
  FAKE_FAIL=TodoItems FAKE_FAIL_MSG="GraphQL: Could not resolve to a User with the login 'me'. (repositoryOwner)" run_script next-tasks.sh
  assert_failure 1
  assert_output --partial "Project が見つかりません: me/4"
}

@test "不明な引数は使い方の誤り（64）で止まる" {
  setup_fake_gh
  run_script next-tasks.sh --foo
  assert_failure 64
  assert_output --partial "不明な引数です: --foo"
}

called() { grep -c "^$1 " "$CALLS" || true; }
args() { grep "^$1 " "$CALLS" | sed -n "${2:-1}p" | cut -d' ' -f2-; }
