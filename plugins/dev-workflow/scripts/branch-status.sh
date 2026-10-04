#!/usr/bin/env bash
# 作業用のブランチが、マージ先のブランチ（base_branch）より遅れているかを調べる。何も変更しない（fetch だけ行う）。
#
# 使い方: branch-status.sh [--branch NAME]
#   --branch NAME  調べるブランチ。省略すると今のブランチ
#
# 出力（JSON）:
#   branch, base          調べたブランチと、取り込み先（base_branch）
#   behind                origin/<base> にあって、ブランチに無いコミットの数
#   ahead                 ブランチにあって、origin/<base> に無いコミットの数
#   up_to_date            behind が 0 か（取り込むものが無いか）
#   pr                    そのブランチの開いている PR（number・url・merge_state）。無ければ null
#                         merge_state は GitHub の mergeStateStatus（BEHIND・DIRTY・BLOCKED・CLEAN など）。
#                         PR が無い、または gh で取得できないときは、pr は null になる
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require gh jq git

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

branch=""
while [ $# -gt 0 ]; do
  case "$1" in
    --branch)
      if [ $# -lt 2 ] || [ -z "$2" ]; then dw_die "--branch に値がありません" 64; fi
      branch="$2"
      shift 2
      ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done

repo_root="$(dw_repo_root)" || dw_die "リポジトリの中で実行してください" 64
config="$("$BASH" "$DW_SCRIPTS_DIR/config.sh")"
base="$(jq -r '.base_branch' <<<"$config")"

if [ -z "$branch" ]; then
  branch="$(git -C "$repo_root" symbolic-ref --short -q HEAD || true)"
  [ -n "$branch" ] || dw_die "ブランチの上にいません。--branch で指定してください" 64
fi
[ "$branch" != "$base" ] || dw_die "${base} には取り込めません。作業用のブランチで実行してください" 64
git -C "$repo_root" show-ref --verify --quiet "refs/heads/$branch" || dw_die "ブランチ ${branch} がありません" 64

git -C "$repo_root" fetch -q origin "$base" || dw_die "origin/${base} を取得できませんでした"
ref="refs/remotes/origin/$base"
git -C "$repo_root" show-ref --verify --quiet "$ref" || dw_die "origin/${base} がありません"

behind="$(git -C "$repo_root" rev-list --count "refs/heads/$branch..$ref")"
ahead="$(git -C "$repo_root" rev-list --count "$ref..refs/heads/$branch")"

pr=null
if prs="$(gh pr list --head "$branch" --state open --json number,url,mergeStateStatus 2>/dev/null)"; then
  pr="$(jq -c 'first // null | if . then {number, url, merge_state: .mergeStateStatus} else null end' <<<"$prs")"
fi

jq -n --arg branch "$branch" --arg base "$base" --argjson behind "$behind" --argjson ahead "$ahead" --argjson pr "$pr" \
  '{branch: $branch, base: $base, behind: $behind, ahead: $ahead, up_to_date: ($behind == 0), pr: $pr}'
