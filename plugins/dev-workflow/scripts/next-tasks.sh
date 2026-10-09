#!/usr/bin/env bash
# Project の Todo の Issue を並び順に読み、次に着手すべきものと、同時に進められる組を JSON で出力する。何も変えない。
#
# 使い方: next-tasks.sh [--issue N]
#   --issue N   Issue N（#N でもよい）と着手中の Issue との重なりだけを出す（task-start が着手する前に確かめる）。
#               N は Project のどの列にあっても、Project に無くてもよい。N が着手中の列にあれば、着手中から除く。
#               重なりの判定は Todo の各 Issue と同じ。依存は読まず、todo・next・parallel・hold は出さない（status.todo も要らない）。
#               出力は {repo, project, issue: {number, title, url, status, areas, areas_ignored, area_known, warnings,
#               conflicts_with_active, overlap, can_defer}, active_unknown, in_progress}。
#               status は Project の列（Project に無い・列が空なら null）。overlap は、重なる着手中の Issue があれば conflict、
#               無くて、N か着手中の Issue の領域が分からなければ unknown、どちらでもなければ none（重なりを優先する）。
#               can_defer は、overlap が conflict で N が Todo の列にあるとき true（依存させて Todo で待てる）
#
# 並び順は Project 上の並び（手動で並べ替えた順）。依存（GitHub の blocked by と、本文の「依存」の #N）に
# 閉じていない Issue（開いている・見つからない）があれば waiting にする。コンフリクトの見込みは、本文の「変更するファイル・領域」と、
# 着手中（start の列と、設定されていれば pr_opened の列）の Issue の開いている PR が変えているファイルで見る
# （パスの一方がもう一方の接頭辞なら重なる）。
# 領域が分からない Issue は、並列にできる組に入れない。「.」「*」「**」はリポジトリ全体として、全部と重なる。
# 領域が「なし」だけの Issue（調査など、リポジトリのファイルを変えないタスク）は、領域が空と分かっているものとして、
# どれとも重ならないとする（着手中でも警告しない。ワークツリーを作らずに着手したタスクには、領域も PR も無いため）。
# パスと判断できない行（日本語の文・途中のグロブ）は areas_ignored に出す。着手中の Issue に領域も PR も無いときは、
# 重なるか分からないので、Todo の各 Issue に warnings を付け、その番号を active_unknown に出す。
# サブ Issue を持つ親の Issue は、作業を子の Issue で進めるので、parent にして候補に入れない。着手中の列にある親は、
# 開いている PR が無ければ着手中として数えない（親には作業が無く、数えると、領域も PR も無いとして全部に警告が付く。
# 本文の領域は子の作業をまとめたものなので、親では使わない）。PR を出した後で子が付いた親は、PR のファイルとの重なりを見る。
# 保留の列（status.hold。設定されていれば）にある Issue は、今は着手できないので候補に入れず、hold に番号とタイトルを出す。
# 出力の next と parallel は、待ちと親を除いた上からの提案。
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(CDPATH='' cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require gh jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

target=""
while [ $# -gt 0 ]; do
  case "$1" in
    --issue)
      { [ $# -ge 2 ] && [ -n "$2" ]; } || dw_die "--issue に値がありません" 64
      target="$(dw_issue_number --issue "$2")"
      shift 2
      ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done

config="$("$BASH" "$DW_SCRIPTS_DIR/config.sh")"
owner="$(jq -r '.project.owner // empty' <<<"$config")"
number="$(jq -r '.project.number // empty' <<<"$config")"
[ -n "$number" ] || dw_die "project.number が未設定です（setup-project.sh --write-config で設定できます）" 2
todo_col="$(jq -r '.status.todo // empty' <<<"$config")"
# --issue では Todo の Issue を扱わないので、status.todo が無くても止めない
# 着手中として数える列。PR を作ると pr_opened の列へ移すリポジトリでは、レビュー中の Issue もそこにあるので含める
active_cols="$(jq -c '[.status.start, .status.pr_opened] | map(select(. != null and . != "")) | unique' <<<"$config")"
[ -n "$todo_col" ] || [ -n "$target" ] || dw_die "status.todo が設定されていません" 2
# 保留の列。設定されていなければ空で、どの Issue も保留にならない
hold_col="$(jq -r '.status.hold // empty' <<<"$config")"
dw_check_hold_column "$config"
sp_name="$(jq -r '.story_point.field' <<<"$config")"
repo_nwo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
[ -n "$owner" ] || owner="${repo_nwo%%/*}"

# Project の項目を、Project 上の並び順（POSITION）で全部読む。gh にも REST にも、並び順を指定して項目を読む手段が無いので
# GraphQL で読む（gh project item-list と REST は起票順で返す。設計書 §8・§10）。ページを辿る
# GraphQL の変数（$owner など）を bash に展開させないため、クエリはシングルクォートで書く
# shellcheck disable=SC2016
query='query TodoItems($owner: String!, $number: Int!, $sp: String!, $after: String) {
  repositoryOwner(login: $owner) { ... on ProjectV2Owner { projectV2(number: $number) {
    items(first: 100, after: $after, orderBy: {field: POSITION, direction: ASC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        content { __typename ... on Issue { number title state body url repository { nameWithOwner } subIssuesSummary { total } } }
        status: fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
        sp: fieldValueByName(name: $sp) { ... on ProjectV2ItemFieldNumberValue { number } }
      }
    }
  } } }
}'
# このリポジトリの開いている Issue を、Todo（todo）と保留（hold）と着手中（start・pr_opened）と、--issue の Issue だけに絞って持つ
# （Done の項目が多くても引数が長くならない）。並びは Project の並びのまま
issues='[]' after=""
while :; do
  vars="$(jq -nc --arg o "$owner" --argjson n "$number" --arg s "$sp_name" --arg a "$after" \
    '{owner: $o, number: $n, sp: $s} + (if $a == "" then {} else {after: $a} end)')"
  # 所有者や Project が無いときは null になる。認証・スコープ不足・通信などの失敗は、dw_gh_find が理由を伝えて止まる
  page="$(dw_gh_find dw_gql "$query" "$vars")"
  jq -e '.data.repositoryOwner.projectV2.items' >/dev/null 2>&1 <<<"$page" \
    || dw_die "Project が見つかりません: ${owner}/${number}（setup-project.sh で設定してください）"
  picked="$(jq -c --arg r "$repo_nwo" --arg todo "$todo_col" --arg hold "$hold_col" --argjson active "$active_cols" \
    --argjson target "${target:-0}" "$DW_JQ_SAME_REPO"'
    [.data.repositoryOwner.projectV2.items.nodes[]
      | select(.content.__typename == "Issue" and same_repo(.content.repository.nameWithOwner; $r) and .content.state == "OPEN")
      | {number: .content.number, title: .content.title, url: .content.url, body: (.content.body // ""),
         status: (.status.name // ""), story_point: (.sp.number // null),
         sub_issues: (.content.subIssuesSummary.total // 0)} | .parent = (.sub_issues > 0)
      | select(($todo != "" and .status == $todo) or ($hold != "" and .status == $hold) or (.status | IN($active[]))
          or .number == $target)]' <<<"$page")"
  # 項目は本文を含んで長くなりうるので、引数ではなく標準入力で jq に渡す（引数1つの長さには上限がある。以下の一覧も同じ）
  issues="$(printf '%s\n' "$issues" "$picked" | jq -sc add)"
  [ "$(jq -r '.data.repositoryOwner.projectV2.items.pageInfo.hasNextPage' <<<"$page")" = true ] || break
  # カーソルが空か前回と同じなら、同じページを読み続けてしまう（無限ループ）ので止める
  next_after="$(jq -r '.data.repositoryOwner.projectV2.items.pageInfo.endCursor // empty' <<<"$page")"
  { [ -n "$next_after" ] && [ "$next_after" != "$after" ]; } \
    || dw_die "Project の項目のページ送りが進みません: ${owner}/${number}"
  after="$next_after"
done

# 本文の節は、issue-depend.sh と同じ読み方（DW_JQ_ISSUE_SECTIONS の section・deps）で読む
# 領域は、箇条書きの1行から、バッククォートで囲んだ最初の語（無ければ最初の空白までの語）をパスとして取る
#   - 「不明」「なし」で始まる行は、領域が無いものとして数えない。「なし」の行（`なし` のようにバッククォートで囲んでもよい）があり、
#     ほかに領域も「不明」の行も無ければ、ファイルを変えない Issue（no_files）として、領域が空と分かっているものとする。
#     どれとも重ならないので、着手中の Issue の「重なるか分からない」警告も付けない
#   - 末尾の /** や /* は外す（ディレクトリ全体）。「.」「*」「**」はリポジトリ全体
#   - 日本語の句読点・括弧を含む語や、途中にグロブ（* ? [）がある語は、パスとして判断できないので areas に入れず
#     areas_ignored に出す（スキルが使う人に伝える）
# jq の変数（$h など）を bash に展開させないため、シングルクォートで書く
# shellcheck disable=SC2016
defs="$DW_JQ_ISSUE_SECTIONS"'
  def area_lines: [section("変更するファイル・領域")[] | select(test("^[ \t]*[-*][ \t]+"))
      | sub("^[ \t]*[-*][ \t]+(\\[[ xX]\\][ \t]+)?"; "")];
  def area_tokens: [area_lines[]
      | (capture("`(?<p>[^`]+)`").p // split("[ \t\u3000]"; null)[0] // "")
      | sub("^\\./(?=.)"; "") | sub("(/\\*+)+/?$"; "") | sub("/+$"; "")
      | if test("^(\\.|\\*+)$") then "." else . end
      | select(. != "" and (test("^(不明|なし)") | not))];
  def unjudgeable: test("[（）、。：]|[*?\\[]");
  def areas: [area_tokens[] | select(unjudgeable | not)] | unique;
  def areas_ignored: [area_tokens[] | select(unjudgeable)] | unique;
  def no_files: [area_lines[] | gsub("`"; "")] as $l
      | (area_tokens | length) == 0 and any($l[]; test("^なし")) and (any($l[]; test("^不明")) | not);
'

# 着手中の Issue。--issue の Issue が着手中の列にあれば（着手し直すとき）、自分とは重ならないので除く
active="$(jq -c "$defs"'[.[] | select((.status | IN($active[])) and .number != $target) | {number, title, parent, areas: areas, no_files: no_files} ]' \
  --argjson active "$active_cols" --argjson target "${target:-0}" <<<"$issues")"

# 着手中の Issue の開いている PR が変えているファイル。PR の Issue は、ブランチ名（<type>/<番号>-…）か Closes で決める
prs="$(gh pr list --state open --limit 1000 --json number,headRefName,files,closingIssuesReferences)" \
  || dw_die "開いている PR を読めませんでした"

# 重なりの判定。Todo の各 Issue と --issue の Issue とで、同じものを使う（jq の定義 odefs）
# shellcheck disable=SC2016
odefs='
  def ov($a; $b): [$a[] as $x | $b[] as $y
      | select($x == "." or $y == "." or $x == $y or ($x | startswith($y + "/")) or ($y | startswith($x + "/"))) | {a: $x, b: $y}];
  def pr_issues: ([.closingIssuesReferences[]?.number]
      + [.headRefName | capture("^[^/]+/(?<n>[0-9]+)-") | .n | tonumber]) | unique;
  # 着手中の Issue に、開いている PR のファイル（pr_files）と、変えるパス（paths）と、それが分かるか（area_known）を付ける。
  # 親を残すかは、PR のファイルの数ではなく、PR があるかで決める（ファイルが空の PR もある）
  def active_paths($prs): map(. as $i | [$prs[] | select(pr_issues | index($i.number))] as $own
    | . + {pr_files: ([$own[].files[]?.path] | unique)}
    | select((.parent | not) or ($own | length > 0)) | if .parent then .areas = [] | .no_files = false else . end
    | .paths = ((.areas + .pr_files) | unique)
    | .area_known = ((.paths | length > 0) or .no_files) | del(.parent, .no_files));
  def unknown_numbers: [.[] | select(.area_known | not) | .number];
  # 領域（areas・no_files）を持つ Issue に、着手中の Issue（active_paths の結果）との重なりを付ける
  def with_overlap($act): . as $t
    | .area_known = ((.areas | length > 0) or .no_files)
    | .warnings = (if .no_files then [] else ($act | unknown_numbers | map("着手中の #\(.) は PR も領域も無く、重なるか分からない")) end)
    | .conflicts_with_active = [$act[] | select(ov($t.areas; .paths) | length > 0) | {issue: .number, paths: ov($t.areas; .paths)}];
'

# --issue では、指定した Issue の重なりだけを出して終える（Todo の Issue・依存・保留は扱わない）。
# Issue は、Project の項目にあればそれを使い、無ければ読む（列は null）
if [ -n "$target" ]; then
  target_item="$(jq -c --argjson t "$target" 'map(select(.number == $t))[0] // empty' <<<"$issues")"
  [ -n "$target_item" ] || target_item="$(dw_read_issue "$target" number,title,body | jq -c '. + {status: null}')"
  printf '%s\n' "$target_item" "$active" "$prs" | jq -s --arg todo "$todo_col" \
    --arg repo "$repo_nwo" --arg owner "$owner" --argjson number "$number" "$defs$odefs"'
    .[0] as $target | .[1] as $active | .[2] as $prs
    | ($active | active_paths($prs)) as $act
    | ($target | {number, title, url, status: (if .status == "" then null else .status end),
        areas: areas, areas_ignored: areas_ignored, no_files: no_files} | with_overlap($act)
        | .overlap = (if (.conflicts_with_active | length) > 0 then "conflict"
            elif (.area_known | not) or (.warnings | length) > 0 then "unknown" else "none" end)
        | .can_defer = (.overlap == "conflict" and $todo != "" and .status == $todo) | del(.no_files)) as $issue
    | {repo: $repo, project: {owner: $owner, number: $number}, issue: $issue,
       active_unknown: ($act | unknown_numbers), in_progress: $act}'
  exit 0
fi

# ここから先は、Todo の Issue の提案（--issue でないとき）だけ
repo_issue_dir="repos/$repo_nwo/issues"
todo="$(jq -c "$defs"'[.[] | select(.status == $todo) | . + {areas: areas, areas_ignored: areas_ignored, body_deps: deps, no_files: no_files} | del(.body)]' \
  --arg todo "$todo_col" <<<"$issues")"
hold="$(jq -c --arg hold "$hold_col" '[.[] | select($hold != "" and .status == $hold) | {number, title, url}]' <<<"$issues")"

# 各 Todo の Issue の依存関係（blocked by）を読み、本文の依存と合わせて、閉じているかを調べる
# 依存先は別のリポジトリの Issue でもありうるので、リポジトリと番号の組で区別する（本文の #N は、このリポジトリの Issue）
# 状態は、依存関係の API が返す（open・closed）。本文だけにある依存は、Project にある Issue（Todo・保留・着手中）なら開いている。
# それ以外は REST で読む
deps='[]'
for n in $(jq -r '.[].number' <<<"$todo"); do
  api_all="$(gh api --paginate "$repo_issue_dir/$n/dependencies/blocked_by?per_page=100" | jq -sc 'add // []')" \
    || dw_die "Issue #${n} の依存関係を読めませんでした"
  body_deps="$(jq -c --argjson n "$n" '.[] | select(.number == $n) | .body_deps' <<<"$todo")"
  deps="$(printf '%s\n' "$deps" "$api_all" "$body_deps" | jq -sc --argjson n "$n" --arg repo "$repo_nwo" "$DW_JQ_SAME_REPO"'
    .[1] as $a | .[2] as $b
    | .[0] + [{number: $n, blockers: (
      (($a | map({repo: ((.repository_url // "") | sub("^.*/repos/"; "") | if . == "" or same_repo(.; $repo) then $repo else . end),
                  number, source: "dependency", state: (.state | ascii_downcase)}))
       + ($b | map({repo: $repo, number: ., source: "body", state: null})))
      | group_by([(.repo | ascii_downcase), .number])
      | map({repo: .[0].repo, number: .[0].number, sources: (map(.source) | unique), state: (map(.state // empty) | first // null)}))}]')"
done
open_in_project="$(printf '%s\n' "$todo" "$active" "$hold" | jq -sc '[.[0][].number] + [.[1][].number] + [.[2][].number]')"
# 状態がまだ分からないもの（このリポジトリの本文の依存で、Project に無いもの）を REST で読む
fetched='{}'
for d in $(printf '%s\n' "$deps" "$open_in_project" | jq -rs --arg repo "$repo_nwo" \
  "$DW_JQ_SAME_REPO"'.[1] as $o | [.[0][].blockers[] | select(.state == null and same_repo(.repo; $repo) and (.number as $x | $o | index($x) | not)) | .number] | unique | .[]'); do
  # 本文の「依存」は手で書くので、無い Issue（404・410）の番号もありうる。止まらず、閉じたと分からないので待ちのままにする
  # （状態は not_found）。認証・通信などほかの失敗は、dw_gh_find が理由を伝えて止まる
  s="$(dw_gh_find gh api "$repo_issue_dir/$d" -q .state)"
  [ "$s" != null ] || s=not_found
  fetched="$(jq -c --arg d "$d" --arg s "$s" '. + {($d): ($s | ascii_downcase)}' <<<"$fetched")"
done

printf '%s\n' "$todo" "$active" "$deps" "$fetched" "$open_in_project" "$hold" "$prs" \
  | jq -s --arg repo "$repo_nwo" --arg owner "$owner" --argjson number "$number" "$DW_JQ_SAME_REPO$odefs"'
  .[0] as $todo | .[1] as $active | .[2] as $deps | .[3] as $fetched | .[4] as $in_project | .[5] as $hold | .[6] as $prs
  | ($active | active_paths($prs)) as $act
  | ($act | unknown_numbers) as $active_unknown
  | ($todo | map(. as $t
      | ($deps[] | select(.number == $t.number).blockers) as $bl
      | . + {blocked_by: ($bl | map(. + {state: (.state // (if same_repo(.repo; $repo) and (.number | IN($in_project[])) then "open"
                                                          else ($fetched[.number | tostring] // "open") end))})
          | map(select(.state != "closed")))}
      | .waiting = (.blocked_by | length > 0)
      | with_overlap($act))) as $items
  | ([$items[] | select((.waiting or .parent) | not)]) as $ready
  | (reduce $ready[] as $r ({sel: [], out: []};
      ([.sel[] | select(ov($r.areas; .areas) | length > 0) | {issue: .number, paths: ov($r.areas; .areas)}]) as $clash
      | if (.sel | length) == 0 then .sel += [$r] | .out += [{number: $r.number, parallel: true, reason: "次に着手する"}]
        elif ((.sel | length) > 0 and (.sel[0].area_known | not)) then .out += [{number: $r.number, parallel: false, reason: "次に着手するものの領域が不明なので、重なるか分からない"}]
        elif ($r.area_known | not) then .out += [{number: $r.number, parallel: false, reason: "領域が不明なので、重なるか分からない"}]
        elif ($clash | length) > 0 then .out += [{number: $r.number, parallel: false, reason: "選んだものと領域が重なる", overlaps: $clash}]
        elif ($r.conflicts_with_active | length) > 0 then .out += [{number: $r.number, parallel: false, reason: "着手中のものと領域が重なる"}]
        else .sel += [$r] | .out += [{number: $r.number, parallel: true, reason: "領域が重ならない"}] end)) as $plan
  | {repo: $repo, project: {owner: $owner, number: $number},
     next: ($plan.sel[0].number // null),
     parallel: [$plan.sel[].number],
     todo: ($items | to_entries | map(.value + {position: (.key + 1)} | del(.no_files) | . as $i
        | . + ((($plan.out[] | select(.number == $i.number)) // {parallel: false, reason: (if $i.parent then "親の Issue（作業は子の Issue で進める）" else "待ち（依存が終わっていない）" end)}) | del(.number)))),
     hold: $hold,
     active_unknown: $active_unknown,
     in_progress: $act}'
