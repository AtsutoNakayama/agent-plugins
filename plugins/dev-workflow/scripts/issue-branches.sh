#!/usr/bin/env bash
# Issue の作業のブランチと、Issue を閉じる開いている PR を探す。task-finish・task-cancel が、片付けるブランチと、
# Issue を閉じてよいかを決めるのに使う（task-start --no-worktree も、同じ判定の dw_issue_work で着手を止めるかを決める）。何も変えない。
#
# 使い方: issue-branches.sh --issue N
#   --issue N   Issue の番号（#N でもよい）
#
# ブランチは2つの段階に分けて出す（片付けで消してよいブランチと、作業があるかもしれないブランチは別のものなので）:
#   - branches（確かなブランチ）：branch.pattern に合い（type は labels.types のどれか）、番号が一致するもの
#     （dw_issue_branches）。片付けや取りやめの対象にするのは、これだけ。マージ済みかは見ない
#     （片付けるときのマージの確かめは、厳密に確かめる cleanup.sh に任せる）
#   - candidates（候補）：名前に「/<番号>-」を含むか「<番号>-」で始まるが branch.pattern に合わないもの（from: name）と、
#     Issue を閉じる PR（開いている・マージ済み。今のリポジトリのもの）のブランチで、手元か origin に残っているもの（from: pr）。関係の無いブランチ
#     （backup/2024-01-15 や、Closes #17, #18 の PR の別の Issue のブランチ）もありうるので、見せて聞くだけにし、自動では触らない
#   origin を読めなければ止まる
# open_prs は、Issue を閉じる PR（closedByPullRequestsReferences）のうち開いているもの（フォークや別のリポジトリの PR も含む）。
# Issue を閉じてよいかの判断に使う
#
# 止まるとき: PR の番号・無い番号（終了コード 2）、branch.pattern が正規表現として正しくない（2）、gh が古い（2）、origin・Issue・PR を読めない（1）
#
# 出力:
#   issue       {number, title, state, url, open_sub_issues（開いている子の数）}
#   branches    [{name, local, remote, worktree（無ければ null）}]
#   candidates  [{name, local, remote, worktree, from（name か pr）, pr（from が pr のときの PR の番号。ほかは null）}]
#   open_prs    [{number, url, branch, cross（フォークか別のリポジトリの PR なら true）}]
#   merged_prs  Issue を閉じる PR のうちマージ済みの、今のリポジトリのもの [{number, url, branch}]（auto-check.sh が使う）
#   action      task-finish がすること（上から順に、当てはまった最初のもの）
#                 cleanup             確かなブランチがある。片付ける（複数あれば、どれかを聞く）
#                 cleanup_candidate   Issue は閉じていて、候補がある。候補で片付けるかを聞く
#                 nothing             Issue は閉じていて、候補も無い。片付けるものも閉じるものも無い
#                 blocked_open_pr     Issue を閉じる PR が開いている。作業はまだ終わっていないので閉じない
#                 blocked_sub_issues  開いている子がある親の Issue。閉じない（親は最後の子を閉じた後に人が閉じる）
#                 ask_close           どれでもない。ワークツリーの無いタスクと決めつけず、閉じるかを聞く
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(CDPATH='' cd "$(dirname "$0")" && pwd)/lib/common.sh"
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
# subIssuesSummary は gh 2.94.0 から読める（closedByPullRequestsReferences はそれより前の 2.73.0 から）
dw_require_gh_version "$DW_GH_MIN_VERSION" "サブ Issue と Issue を閉じる PR を読む（gh issue view --json subIssuesSummary,closedByPullRequestsReferences）"

# PR の番号なら止まる（dw_read_issue。PR を Issue として閉じないため）
issue_json="$(dw_read_issue "$issue" number,title,state,subIssuesSummary,closedByPullRequestsReferences)"
# 確かなブランチ・候補・開いている PR を求める（dw_issue_work。origin・PR を読めなければ止まる）
work="$(dw_issue_work "$main_root" "$issue" "$config" "$issue_json")"

# task-finish がすることを、上から順に当てはまったもので決める（判断をスキルの文章に置かず、bats で組み合わせを確かめるため）
# ブランチの一覧（work）は長くなりうるので、引数ではなく標準入力で jq に渡す（引数1つの長さには上限がある）
printf '%s\n' "$issue_json" "$work" | jq -s '
  .[0] as $i | .[1] as $w
  | {issue: {number: $i.number, title: $i.title, state: $i.state, url: $i.url,
           open_sub_issues: (($i.subIssuesSummary.total // 0) - ($i.subIssuesSummary.completed // 0))}} + $w
  | .action = (
      if (.branches | length) > 0 then "cleanup"
      elif .issue.state == "CLOSED" then (if (.candidates | length) > 0 then "cleanup_candidate" else "nothing" end)
      elif (.open_prs | length) > 0 then "blocked_open_pr"
      elif .issue.open_sub_issues > 0 then "blocked_sub_issues"
      else "ask_close" end)'
