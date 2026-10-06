#!/usr/bin/env bash
# Issue の作業のブランチと、Issue を閉じる開いている PR を探す。task-finish・task-cancel が、片付けるブランチと、
# Issue を閉じてよいかを決めるのに使う。何も変えない。
#
# 使い方: issue-branches.sh --issue N
#   --issue N   Issue の番号（#N でもよい）
#
# ブランチは2つの段階に分けて出す（片付けで消してよいブランチと、作業があるかもしれないブランチは別のものなので）:
#   - branches（確かなブランチ）：branch.pattern に合い（type は labels.types のどれか）、番号が一致するもの
#     （dw_issue_branches）。片付けや取りやめの対象にするのは、これだけ。作業の状態（dw_branch_state）を state と pr に出す
#     （open: 開いている PR がある。merged: 先端がマージ済みの PR に含まれる。none: どちらでもない＝作業が残っている）
#   - candidates（候補）：名前に「/<番号>-」を含むか「<番号>-」で始まるが branch.pattern に合わないもの（from: name）と、
#     Issue を閉じる PR（開いている・マージ済み。今のリポジトリのもの）のブランチで、手元か origin に残っているもの（from: pr）。関係の無いブランチ
#     （backup/2024-01-15 や、Closes #17, #18 の PR の別の Issue のブランチ）もありうるので、見せて聞くだけにし、自動では触らない
#   origin を読めなければ止まる
# open_prs は、Issue を閉じる PR（closedByPullRequestsReferences）のうち開いているもの（フォークや別のリポジトリの PR も含む）。
# Issue を閉じてよいかの判断に使う
#
# 止まるとき: PR の番号・無い番号（終了コード 2）、gh が古い（2）、origin・Issue・PR を読めない（1）
#
# 出力:
#   issue       {number, title, state, url, open_sub_issues（開いている子の数）}
#   branches    [{name, local, remote, worktree（無ければ null）, state（open・merged・none）, pr（state の元の PR の番号。無ければ null）}]
#   candidates  [{name, local, remote, worktree, from（name か pr）, pr（from が pr のときの PR の番号。ほかは null）}]
#   open_prs    [{number, url, branch}]
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require gh jq git

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

issue=""
while [ $# -gt 0 ]; do
  case "$1" in
    --issue)
      [ $# -ge 2 ] && [ -n "$2" ] || dw_die "--issue に値がありません" 64
      issue="$2"
      shift 2
      ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done
[ -n "$issue" ] || dw_die "--issue は必須です" 64
issue="$(dw_issue_number --issue "$issue")"

repo_root="$(dw_repo_root)" || dw_die "リポジトリの中で実行してください" 64
main_root="$(dw_main_root "$repo_root")" || dw_die "メインのワークツリーが分かりません"
config="$("$BASH" "$DW_SCRIPTS_DIR/config.sh")"
# closedByPullRequestsReferences は gh 2.73.0 から読める（プラグインが求める版はそれより新しい）
dw_require_gh_version "$DW_GH_MIN_VERSION" "Issue を閉じる PR を読む（gh issue view --json closedByPullRequestsReferences）"

# PR の番号なら止まる（dw_read_issue。PR を Issue として閉じないため）
issue_json="$(dw_read_issue "$issue" number,title,state,subIssuesSummary,closedByPullRequestsReferences)"
found="$(dw_issue_branches "$main_root" "$issue" "$config")"

# 名前で見つかったブランチ（ふつう数本）ごとに、ワークツリーの場所と、確かなブランチならマージ済みの PR を足す
branches='[]' candidates='[]'
while IFS="$(printf '\t')" read -r b is_local is_remote confirmed; do
  [ -n "$b" ] || continue
  wt=""
  [ "$is_local" = true ] && wt="$(dw_live_worktree_of "$main_root" "$b")"
  if [ "$confirmed" = true ]; then
    # 先に変数で受ける（PR を読めなければ止まる）
    st="$(dw_branch_state "$main_root" "$b")"
    branches="$(jq -c --arg b "$b" --argjson l "$is_local" --argjson r "$is_remote" --arg w "$wt" --arg st "$st" \
      '($st | split("\t")) as $s | . + [{name: $b, local: $l, remote: $r, worktree: (if $w == "" then null else $w end),
             state: $s[0], pr: (if ($s[1] // "") == "" then null else ($s[1] | tonumber) end)}]' <<<"$branches")"
  else
    candidates="$(jq -c --arg b "$b" --argjson l "$is_local" --argjson r "$is_remote" --arg w "$wt" \
      '. + [{name: $b, local: $l, remote: $r, worktree: (if $w == "" then null else $w end), from: "name", pr: null}]' <<<"$candidates")"
  fi
done <<<"$found"

# Issue を閉じる PR（closedByPullRequestsReferences は状態を返さないので、PR ごとに読む）。
# 開いているものは open_prs に、今のリポジトリの PR のブランチは、まだ出していなければ候補に足す。
# リポジトリの名前は、Issue を閉じる PR があるときだけ読む
nwo=""
if jq -e '(.closedByPullRequestsReferences // []) | length > 0' <<<"$issue_json" >/dev/null; then
  nwo="$(gh repo view --json nameWithOwner -q .nameWithOwner)" || dw_die "リポジトリの名前を読めませんでした"
fi
open_prs='[]'
while IFS="$(printf '\t')" read -r url pr_repo; do
  [ -n "$url" ] || continue
  pr="$(gh pr view "$url" --json number,url,state,headRefName,isCrossRepository)" || dw_die "PR ${url} を読めませんでした"
  open_prs="$(jq -c --argjson p "$pr" \
    'if $p.state == "OPEN" then . + [{number: $p.number, url: $p.url, branch: $p.headRefName}] else . end' <<<"$open_prs")"
  head="$(jq -r 'select((.state == "OPEN" or .state == "MERGED") and (.isCrossRepository | not)) | .headRefName' <<<"$pr")"
  [ -n "$head" ] && [ "$pr_repo" = "$nwo" ] || continue
  if jq -e --arg h "$head" 'any(.[]; .name == $h)' <<<"$branches" >/dev/null \
    || jq -e --arg h "$head" 'any(.[]; .name == $h)' <<<"$candidates" >/dev/null; then
    continue
  fi
  is_local=false
  git -C "$main_root" show-ref --verify --quiet "refs/heads/$head" && is_local=true
  is_remote=false
  dw_remote_has_branch "$main_root" "$head" && is_remote=true
  # 手元にも origin にも無いブランチ（マージして片付け終えたものなど）は、片付けるものが無いので候補に出さない
  [ "$is_local" = true ] || [ "$is_remote" = true ] || continue
  wt=""
  [ "$is_local" = true ] && wt="$(dw_live_worktree_of "$main_root" "$head")"
  candidates="$(jq -c --arg b "$head" --argjson l "$is_local" --argjson r "$is_remote" --arg w "$wt" --argjson n "$(jq .number <<<"$pr")" \
    '. + [{name: $b, local: $l, remote: $r, worktree: (if $w == "" then null else $w end), from: "pr", pr: $n}]' <<<"$candidates")"
done < <(jq -r '.closedByPullRequestsReferences // [] | .[]
  | [.url, (if .repository then "\(.repository.owner.login)/\(.repository.name)" else "" end)] | @tsv' <<<"$issue_json")

jq -n --argjson i "$issue_json" --argjson b "$branches" --argjson c "$candidates" --argjson o "$open_prs" '{
  issue: {number: $i.number, title: $i.title, state: $i.state, url: $i.url,
          open_sub_issues: (($i.subIssuesSummary.total // 0) - ($i.subIssuesSummary.completed // 0))},
  branches: $b,
  candidates: $c,
  open_prs: $o
}'
