#!/usr/bin/env bash
# Issue の作業のブランチと、Issue を閉じる開いている PR を探す。task-finish・task-cancel が、片付けるブランチと、
# Issue を閉じてよいかを決めるのに使う。何も変えない。
#
# 使い方: issue-branches.sh --issue N
#   --issue N   Issue の番号（#N でもよい）
#
# 探すもの:
#   - ブランチ：名前だけで探す（dw_issue_branches）。手元と origin のブランチのうち、名前に「/<番号>-」を含むか
#     「<番号>-」で始まるもの。branch.pattern に合わない名前や、先頭に 0 が付いた古い名前も含めて広めに探す。
#     PR からは探さない（Closes #17, #18 の PR やリリース用の PR のように、別の Issue のブランチまで拾うため）。
#     origin を読めなければ止まる
#   - 開いている PR：Issue を閉じる PR（Closes #N など。gh issue view の closedByPullRequestsReferences）のうち、開いているもの。
#     フォークや別のリポジトリの PR も含む。ブランチを探すのには使わず、Issue を閉じてよいかの判断にだけ使う
#
# 止まるとき: PR の番号・無い番号（終了コード 2）、gh が古い（2）、origin や Issue を読めない（1）
#
# 出力:
#   issue     {number, title, state, url, open_sub_issues（開いている子の数）}
#   branches  名前で見つかったブランチ。[{name, local, remote, worktree（無ければ null）}]
#   open_prs  Issue を閉じる、開いている PR。[{number, url, branch}]
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
# closedByPullRequestsReferences は gh 2.73.0 から読める（プラグインが求める版はそれより新しい）
dw_require_gh_version "$DW_GH_MIN_VERSION" "Issue を閉じる PR を読む（gh issue view --json closedByPullRequestsReferences）"

# PR の番号なら止まる（dw_read_issue。PR を Issue として閉じないため）
issue_json="$(dw_read_issue "$issue" number,title,state,subIssuesSummary,closedByPullRequestsReferences)"
found="$(dw_issue_branches "$main_root" "$issue")"

# ワークツリーの場所は、見つかった手元のブランチ（ふつう1〜2本）だけで引く。ディレクトリを手で消した記録は、無いものとする
worktrees='{}'
while IFS="$(printf '\t')" read -r b is_local _; do
  [ "$is_local" = true ] || continue
  p="$(dw_worktree_of "$main_root" "$b")"
  if [ -n "$p" ] && [ -d "$p" ]; then
    worktrees="$(jq -c --arg b "$b" --arg p "$p" '. + {($b): $p}' <<<"$worktrees")"
  fi
done <<<"$found"
branches="$(printf '%s\n' "$found" | jq -R -s -c --argjson wt "$worktrees" '
  split("\n") | map(select(. != "") | split("\t")
    | {name: .[0], local: (.[1] == "true"), remote: (.[2] == "true"), worktree: ($wt[.[0]] // null)})')"

# Issue を閉じる PR のうち、開いているもの（closedByPullRequestsReferences は状態を返さないので、PR ごとに読む）
open_prs='[]'
while IFS= read -r url; do
  [ -n "$url" ] || continue
  pr="$(gh pr view "$url" --json number,url,state,headRefName)" || dw_die "PR ${url} を読めませんでした"
  open_prs="$(jq -c --argjson p "$pr" \
    'if $p.state == "OPEN" then . + [{number: $p.number, url: $p.url, branch: $p.headRefName}] else . end' <<<"$open_prs")"
done < <(jq -r '.closedByPullRequestsReferences // [] | .[].url' <<<"$issue_json")

jq -n --argjson i "$issue_json" --argjson b "$branches" --argjson o "$open_prs" '{
  issue: {number: $i.number, title: $i.title, state: $i.state, url: $i.url,
          open_sub_issues: (($i.subIssuesSummary.total // 0) - ($i.subIssuesSummary.completed // 0))},
  branches: $b,
  open_prs: $o
}'
