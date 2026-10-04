#!/usr/bin/env bash
# 必須のチェックを出すワークフローが、マージキューの merge_group のイベントでも動くかを確かめる。何も変更しない。
# キューは必須のチェックを merge_group のイベントでもう一度動かしてからマージするので、動かないワークフローの
# チェックは「待ち」のまま残り、PR がマージされない。setup-repo.sh と doctor.sh が使う。
#
# 使い方: merge-group-check.sh --branch NAME [--repo OWNER/NAME] [--check NAME]...
#   --branch NAME    ワークフローを読むブランチ（base_branch。キューはこのブランチのワークフローを動かす）
#   --repo OWNER/NAME  対象のリポジトリ（既定: 今いるリポジトリ）
#   --check NAME     必須のチェックの名前（繰り返し指定できる。無ければ何も読まずに空の結果を出す）
#
# 確かめ方:
#   ブランチの .github/workflows/*.yml・*.yaml を GitHub の API で読む（手元の作業中のファイルではなく、
#   キューで動く GitHub 上のものを見る）。YAML のパーサーは前提にしないので、次の簡易な読み方をする。
#   - merge_group で動くか：トップレベルの on: の範囲（on: の行から次のトップレベルのキーまで）に、
#     merge_group という語があるか
#   - チェックとジョブの対応：チェックの名前を、jobs: の下のジョブの ID か name: と突き合わせる。
#     matrix の「名前 (値)」は括弧の前でも、再利用するワークフローの「呼ぶ側 / 呼ばれる側」は / の前でも比べ、
#     name: の ${{ }} の式は何にでも当てはまるものとして比べる（式のほかに英数字が無い name は、どのチェックにも
#     当たってしまうので、式としては比べない）
#   対応するジョブがあるワークフローのどれも merge_group で動かなければ not_running に、
#   どのジョブとも対応しない名前（外部のアプリのチェックなど）は unknown に入れる。
#
# 出力（JSON）:
#   branch        読んだブランチ
#   workflows     読んだワークフローのファイル
#   not_running   merge_group で動かないチェック（check と、対応するジョブがあるワークフローの workflows）
#   unknown       どのジョブとも対応せず、確かめられないチェックの名前
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require gh jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

need_value() {
  if [ $# -lt 2 ] || [ -z "$2" ]; then
    dw_die "$1 に値がありません" 64
  fi
}

# gh api は {owner}/{repo} を今いるリポジトリに置き換える
repo="{owner}/{repo}" branch=""
checks=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) need_value "$@"; repo="$2"; shift 2 ;;
    --branch) need_value "$@"; branch="$2"; shift 2 ;;
    --check) need_value "$@"; checks+=("$2"); shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done
[ -n "$branch" ] || dw_die "--branch を指定してください" 64

checks_json="$(printf '%s\n' ${checks[@]+"${checks[@]}"} | jq -R -s -c 'split("\n") | map(select(. != "")) | unique')"
if [ "$checks_json" = "[]" ]; then
  jq -n --arg b "$branch" '{branch: $b, workflows: [], not_running: [], unknown: []}'
  exit 0
fi

# ワークフローの一覧。ディレクトリが無ければ（404）ワークフローは無い
ref="$(jq -rn --arg b "$branch" '$b | @uri')"
if ! listing="$(gh api "repos/$repo/contents/.github/workflows?ref=$ref" 2>&1)"; then
  case "$listing" in
    *"HTTP 404"*) listing='[]' ;;
    *) dw_die "${branch} のワークフローの一覧を読めません: $listing" ;;
  esac
fi
workflows="$(jq -c '[if type == "array" then .[] else empty end
  | select(.type == "file" and (.name | test("\\.ya?ml$"))) | .path]' <<<"$listing" 2>/dev/null)" \
  || dw_die "${branch} のワークフローの一覧を JSON として読めません"

# ワークフローを読み、merge_group で動くか（「on <0|1>」の1行）と、ジョブ（「job <ID> <name> <name の式を * にした形>」。
# 項目は \037 で区切る（タブでは、read が空の項目を詰めてしまう）。name が無ければ空、式が無ければ形は空）を出力する。インデントは空白だけとみなす（YAML はタブを許さない）
parse_workflow() {
  awk '
    function strip(s) {
      sub(/\r$/, "", s)
      if (s ~ /^[ \t]*#/) return ""
      sub(/[ \t]#.*$/, "", s)
      return s
    }
    function unquote(s) {
      sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s)
      if (s ~ /^".*"$/ || s ~ /^\047.*\047$/) s = substr(s, 2, length(s) - 2)
      return s
    }
    function flush() {
      if (id != "") {
        pat = ""
        if (name ~ /\$\{\{/) {
          pat = name; gsub(/\$\{\{[^}]*\}\}/, "*", pat)
          # 英数字が残らない形（「*」「* (*)」など）は、関係の無いチェックにも当たるので使わない
          lit = pat; gsub(/[^A-Za-z0-9]/, "", lit)
          if (lit == "") pat = ""
        }
        printf "job\037%s\037%s\037%s\n", id, name, pat
      }
      id = ""; name = ""; childind = -1
    }
    BEGIN { section = ""; mg = 0; jobind = -1; childind = -1 }
    {
      s = strip($0)
      if (s ~ /^[ \t]*$/) next
      if (s ~ /^[^ ]/) {
        flush()
        if (s ~ /^("on"|\047on\047|on|true)[ \t]*:/) section = "on"
        else if (s ~ /^jobs[ \t]*:/) section = "jobs"
        else section = ""
      }
      if (section == "on") {
        if ((" " s " ") ~ /[^A-Za-z0-9_-]merge_group[^A-Za-z0-9_-]/) mg = 1
        next
      }
      if (section != "jobs" || s ~ /^[^ ]/) next
      match(s, /^ */); ind = RLENGTH
      if (jobind < 0) jobind = ind
      if (ind == jobind) {
        flush()
        id = s; sub(/:.*$/, "", id); id = unquote(id)
      } else if (ind > jobind && id != "") {
        if (childind < 0) childind = ind
        if (ind == childind && s ~ /^ *name[ \t]*:/) {
          v = s; sub(/^ *name[ \t]*:/, "", v); name = unquote(v)
        }
      }
    }
    END { flush(); printf "on\037%d\n", mg }
  ' "$1"
}

# チェックの名前と比べる候補（そのまま・matrix の括弧の前・再利用の / の前）を1行ずつ出力する
candidates() {
  printf '%s\n' "$1" "${1% (*}" "${1%% / *}"
}

# 使い方: job_matches <チェックの名前> <ジョブの ID> <name> <name の式を * にした形>
job_matches() {
  local c
  while IFS= read -r c; do
    if [ "$c" = "$2" ] || { [ -n "$3" ] && [ "$c" = "$3" ]; }; then
      return 0
    fi
    if [ -n "$4" ]; then
      # 式を * にした形をグロブとして当てる（意図して引用しない）
      # shellcheck disable=SC2254
      case "$c" in $4) return 0 ;; esac
    fi
  done <<EOF
$(candidates "$1")
EOF
  return 1
}

sep=$'\037'
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# チェックごとに、対応するジョブがあるワークフロー（matched）と、そのうち merge_group で動くか（running）を集める
result="$(jq -c 'map({key: ., value: {matched: [], running: false}}) | from_entries' <<<"$checks_json")"
while IFS= read -r path; do
  [ -n "$path" ] || continue
  dw_fetch_repo_file "$repo" "$path" "$tmp/workflow" "$branch" || continue
  parsed="$(parse_workflow "$tmp/workflow")"
  mg="$(printf '%s\n' "$parsed" | awk -F "$sep" '$1 == "on" { print $2 }')"
  while IFS= read -r check; do
    while IFS="$sep" read -r kind id name pat; do
      [ "$kind" = job ] || continue
      if job_matches "$check" "$id" "$name" "$pat"; then
        result="$(jq -c --arg c "$check" --arg p "$path" --argjson mg "$mg" \
          '.[$c].matched += [$p] | .[$c].matched |= unique | .[$c].running = (.[$c].running or $mg == 1)' <<<"$result")"
        break
      fi
    done <<EOF
$parsed
EOF
  done < <(jq -r '.[]' <<<"$checks_json")
done < <(jq -r '.[]' <<<"$workflows")

jq -n --arg b "$branch" --argjson w "$workflows" --argjson r "$result" '{
  branch: $b,
  workflows: $w,
  not_running: [$r | to_entries[] | select((.value.matched | length) > 0 and (.value.running | not))
    | {check: .key, workflows: .value.matched}],
  unknown: [$r | to_entries[] | select((.value.matched | length) == 0) | .key]
}'
