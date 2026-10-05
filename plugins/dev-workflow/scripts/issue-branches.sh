#!/usr/bin/env bash
# Issue の作業のブランチと PR を探す。task-finish・task-cancel が、片付けるブランチを決めるのに使う。何も変えない。
#
# 使い方: issue-branches.sh --issue N
#   --issue N   Issue の番号（#N でもよい）
#
# 探すもの:
#   - 名前で：手元のブランチと origin のブランチのうち、branch.pattern に当てた Issue の番号が N のもの
#     （origin を読めなければ警告して、手元だけで探す）
#   - PR で：Issue に紐付く PR（Closes #N など。gh issue view の closedByPullRequestsReferences）。
#     規約に合わない名前のブランチで作業していても見つかる。Issue の側から読むので、PR の件数の上限を受けない。
#     マージせずに閉じた PR は、作業が残っていないので除く
#
# 出力:
#   branches  片付けの対象のブランチ。名前で見つかったものと、今のリポジトリの PR（fork が false）のブランチ。
#             [{name, local, remote, worktree（無ければ null）, pr（紐付く PR の番号。無ければ null）}]
#   prs       紐付く PR（開いている・マージ済み）。[{number, url, state, branch, fork}]
#             fork は、ブランチが origin に無い PR（フォークからの PR、別のリポジトリの PR）。手元では片付けられない
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

# ブランチ名が、この Issue のものか（branch.pattern に当てた番号が一致するか）
is_ours() { [ "$(dw_parse_branch "$config" "$1" | cut -d'|' -f2)" = "$issue" ]; }

# --- 名前で探す -------------------------------------------------------------------
local_names="$(git -C "$main_root" for-each-ref --format='%(refname:short)' refs/heads/)"
if remote_refs="$(git -C "$main_root" ls-remote --heads origin 2>/dev/null)"; then
  remote_names="$(sed -n 's|^[0-9a-f]*[[:space:]]*refs/heads/||p' <<<"$remote_refs")"
else
  dw_warn "origin のブランチを読めませんでした。手元のブランチだけで探します"
  remote_names=""
fi
named='[]'
while IFS= read -r b; do
  [ -n "$b" ] && is_ours "$b" && named="$(jq -c --arg b "$b" '. + [$b]' <<<"$named")"
done <<<"$(printf '%s\n%s\n' "$local_names" "$remote_names" | sort -u)"

# --- PR で探す --------------------------------------------------------------------
issue_json="$(gh issue view "$issue" --json closedByPullRequestsReferences)" \
  || dw_die "Issue #${issue} を読めませんでした"
nwo="$(gh repo view --json nameWithOwner -q .nameWithOwner)" || dw_die "リポジトリの名前を読めませんでした"
prs='[]'
while IFS=$'\t' read -r url pr_repo; do
  [ -n "$url" ] || continue
  pr="$(gh pr view "$url" --json number,url,state,headRefName,isCrossRepository)" \
    || dw_die "PR ${url} を読めませんでした"
  prs="$(jq -c --argjson p "$pr" --arg r "$pr_repo" --arg nwo "$nwo" '
    if $p.state == "CLOSED" then . else
      . + [{number: $p.number, url: $p.url, state: $p.state, branch: $p.headRefName,
            fork: ($p.isCrossRepository or ($r != "" and ($r | ascii_downcase) != ($nwo | ascii_downcase)))}]
    end' <<<"$prs")"
done < <(jq -r '.closedByPullRequestsReferences // [] | .[]
  | [.url, (if .repository then "\(.repository.owner.login)/\(.repository.name)" else "" end)] | @tsv' <<<"$issue_json")

# --- まとめる ---------------------------------------------------------------------
worktrees="$(git -C "$main_root" worktree list --porcelain \
  | awk '/^worktree /{p=substr($0, 10)} /^branch refs\/heads\//{print substr($0, 19) "\t" p}' \
  | jq -R -s -c 'split("\n") | map(select(. != "") | split("\t") | {key: .[0], value: .[1]}) | from_entries')"
jq -n --argjson i "$issue" --argjson named "$named" --argjson prs "$prs" --argjson wt "$worktrees" \
  --arg local "$local_names" --arg remote "$remote_names" '
  ($local | split("\n")) as $l | ($remote | split("\n")) as $r
  | ($named + [$prs[] | select(.fork | not) | .branch] | unique) as $names
  | {
      issue: $i,
      branches: [$names[] as $b | {
        name: $b,
        local: ($l | index($b) != null),
        remote: ($r | index($b) != null),
        worktree: ($wt[$b] // null),
        pr: ([$prs[] | select((.fork | not) and .branch == $b) | .number] | first // null)
      }],
      prs: $prs
    }'
