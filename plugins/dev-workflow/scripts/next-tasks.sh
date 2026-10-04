#!/usr/bin/env bash
# Project の Todo の Issue を並び順に読み、次に着手すべきものと、同時に進められる組を JSON で出力する。何も変えない。
#
# 使い方: next-tasks.sh
#
# 並び順は Project 上の並び（手動で並べ替えた順）。依存（GitHub の blocked by と、本文の「依存」の #N）に
# 閉じていない Issue があれば waiting にする。コンフリクトの見込みは、本文の「変更するファイル・領域」と、
# 着手中（start の列）の Issue の開いている PR が変えているファイルで見る（パスの一方がもう一方の接頭辞なら重なる）。
# 領域が分からない Issue は、並列にできる組に入れない。出力の next と parallel は、待ちを除いた上からの提案。
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require gh jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done

config="$("$BASH" "$DW_SCRIPTS_DIR/config.sh")"
owner="$(jq -r '.project.owner // empty' <<<"$config")"
number="$(jq -r '.project.number // empty' <<<"$config")"
[ -n "$number" ] || dw_die "project.number が未設定です（setup-project.sh --write-config で設定できます）" 2
todo_col="$(jq -r '.status.todo // empty' <<<"$config")"
start_col="$(jq -r '.status.start // empty' <<<"$config")"
[ -n "$todo_col" ] || dw_die "status.todo が設定されていません" 2
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
        content { __typename ... on Issue { number title state body url repository { nameWithOwner } } }
        status: fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
        sp: fieldValueByName(name: $sp) { ... on ProjectV2ItemFieldNumberValue { number } }
      }
    }
  } } }
}'
# このリポジトリの開いている Issue を、Todo（todo）と着手中（start）だけに絞って持つ（Done の項目が多くても引数が長くならない）。
# 並びは Project の並びのまま
issues='[]' after=""
while :; do
  vars="$(jq -nc --arg o "$owner" --argjson n "$number" --arg s "$sp_name" --arg a "$after" \
    '{owner: $o, number: $n, sp: $s} + (if $a == "" then {} else {after: $a} end)')"
  page="$(dw_gql "$query" "$vars")" || dw_die "Project の項目を読めませんでした"
  jq -e '.data.repositoryOwner.projectV2.items' >/dev/null <<<"$page" \
    || dw_die "Project が見つかりません: ${owner}/${number}（setup-project.sh で設定してください）"
  picked="$(jq -c --arg r "$repo_nwo" --arg todo "$todo_col" --arg start "$start_col" '
    [.data.repositoryOwner.projectV2.items.nodes[]
      | select(.content.__typename == "Issue" and .content.repository.nameWithOwner == $r and .content.state == "OPEN")
      | {number: .content.number, title: .content.title, url: .content.url, body: (.content.body // ""),
         status: (.status.name // ""), story_point: (.sp.number // null)}
      | select(.status == $todo or (.status == $start and $start != ""))]' <<<"$page")"
  issues="$(jq -c --argjson p "$picked" '. + $p' <<<"$issues")"
  [ "$(jq -r '.data.repositoryOwner.projectV2.items.pageInfo.hasNextPage' <<<"$page")" = true ] || break
  after="$(jq -r '.data.repositoryOwner.projectV2.items.pageInfo.endCursor' <<<"$page")"
done

# 本文の見出し（## <見出し>）の次の行から、次の見出しまでを行の配列にする
# 領域は、箇条書きの1行から、バッククォートで囲んだ最初の語（無ければ最初の空白までの語）をパスとして取る
# jq の変数（$h など）を bash に展開させないため、シングルクォートで書く
# shellcheck disable=SC2016
defs='
  def section($h): (.body | gsub("\r"; "") | split("\n"))
    | reduce .[] as $l ({on: false, out: []};
        if ($l | test("^## ")) then .on = ($l | test("^##[ \t]*" + $h + "[ \t]*$"))
        elif .on then .out += [$l] else . end) | .out;
  def deps: [section("依存")[] | scan("#([0-9]+)") | .[0] | tonumber] | unique;
  def areas: [section("変更するファイル・領域")[] | select(test("^[ \t]*[-*][ \t]+"))
      | sub("^[ \t]*[-*][ \t]+(\\[[ xX]\\][ \t]+)?"; "")
      | (capture("`(?<p>[^`]+)`").p // split(" ")[0] // "")
      | sub("^\\./"; "") | sub("/+$"; "")
      | select(. != "" and . != "なし" and . != "不明")] | unique;
'

repo_issue_dir="repos/$repo_nwo/issues"
todo="$(jq -c "$defs"'[.[] | select(.status == $todo) | . + {areas: areas, body_deps: deps} | del(.body)]' \
  --arg todo "$todo_col" <<<"$issues")"
active="$(jq -c "$defs"'[.[] | select(.status == $start and $start != "") | {number, title, areas: areas} ]' \
  --arg start "$start_col" <<<"$issues")"

# 各 Todo の Issue の依存関係（blocked by）を読み、本文の依存と合わせて、閉じているかを調べる
# 状態は、Project にある Issue（Todo・着手中）なら開いている。依存関係の API は状態も返す。それ以外の番号だけ REST で読む
open_in_project="$(jq -c --argjson a "$active" '[.[].number] + [$a[].number]' <<<"$todo")"
states='{}'
deps='[]'
for n in $(jq -r '.[].number' <<<"$todo"); do
  api_all="$(gh api --paginate "$repo_issue_dir/$n/dependencies/blocked_by?per_page=100" | jq -sc 'add // []')" \
    || dw_die "Issue #${n} の依存関係を読めませんでした"
  api_deps="$(jq -c 'map(.number)' <<<"$api_all")"
  # 依存関係の API は、相手の状態（open・closed）も返す
  states="$(jq -c --argjson a "$api_all" '. + ($a | map({(.number | tostring): (.state | ascii_downcase)}) | add // {})' <<<"$states")"
  body_deps="$(jq -c --argjson n "$n" '.[] | select(.number == $n) | .body_deps' <<<"$todo")"
  deps="$(jq -c --argjson n "$n" --argjson a "$api_deps" --argjson b "$body_deps" \
    '. + [{number: $n, blockers: ((($a | map({number: ., source: "dependency"})) + ($b | map({number: ., source: "body"}))) | group_by(.number)
      | map({number: .[0].number, sources: (map(.source) | unique)}))}]' <<<"$deps")"
done
# 本文だけにある依存のうち、状態がまだ分からないもの（Project にあるものと、依存関係の API で分かったものを除く）を REST で読む
for d in $(jq -r --argjson o "$open_in_project" --argjson s "$states" \
  '[.[].blockers[].number] | unique | map(select(. as $x | ($o | index($x) | not) and ($s | has($x | tostring) | not))) | .[]' <<<"$deps"); do
  s="$(gh api "$repo_issue_dir/$d" -q .state)" || dw_die "Issue #${d} を読めませんでした"
  states="$(jq -c --arg d "$d" --arg s "$s" '. + {($d): ($s | ascii_downcase)}' <<<"$states")"
done

# 着手中の Issue の開いている PR が変えているファイル。PR の Issue は、ブランチ名（<type>/<番号>-…）か Closes で決める
prs="$(gh pr list --state open --limit 100 --json number,headRefName,files,closingIssuesReferences)" \
  || dw_die "開いている PR を読めませんでした"

jq -n --argjson todo "$todo" --argjson active "$active" --argjson deps "$deps" --argjson states "$states" \
  --argjson prs "$prs" --arg repo "$repo_nwo" --arg owner "$owner" --argjson number "$number" '
  def ov($a; $b): [$a[] as $x | $b[] as $y
      | select($x == $y or ($x | startswith($y + "/")) or ($y | startswith($x + "/"))) | {a: $x, b: $y}];
  def pr_issues: ([.closingIssuesReferences[]?.number]
      + [.headRefName | capture("^[^/]+/(?<n>[0-9]+)-") | .n | tonumber]) | unique;
  ($active | map(. as $i | . + {pr_files: ([$prs[] | select(pr_issues | index($i.number)) | .files[]?.path] | unique)}
    | .paths = ((.areas + .pr_files) | unique))) as $act
  | ($todo | map(. as $t
      | ($deps[] | select(.number == $t.number).blockers) as $bl
      | . + {blocked_by: ($bl | map(. + {state: (if (.number | tostring) | in($states) then $states[.number | tostring] else "open" end)})
          | map(select(.state == "open")))}
      | .waiting = (.blocked_by | length > 0)
      | .area_known = (.areas | length > 0)
      | .conflicts_with_active = [$act[] | select(ov($t.areas; .paths) | length > 0) | {issue: .number, paths: ov($t.areas; .paths)}])) as $items
  | ([$items[] | select(.waiting | not)]) as $ready
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
     todo: ($items | to_entries | map(.value + {position: (.key + 1)} | . as $i
        | . + ((($plan.out[] | select(.number == $i.number)) // {parallel: false, reason: "待ち（依存が終わっていない）"}) | del(.number)))),
     in_progress: $act}'
