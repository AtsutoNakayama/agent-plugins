#!/usr/bin/env bash
# 既にある Issue を、起票する Issue の親にできるかを判定して、JSON で出力する。何も変えない。
# task-create で、分けた Issue の案の木の一番上の親を「外す」とき、外した親の代わりに、重なる既にある Issue を
# 子の親にできるかを決める。確認と文章は呼ぶ側（スキル）が担当する。
#
# 使い方: parent-candidate.sh --issue N [--levels L]
#   --issue N   親にする候補の、同じリポジトリの Issue の番号（#N でもよい）
#   --levels L  候補の下に紐付ける層の数（既定 1）。外した親の子だけなら 1、その子にさらに子（孫）があれば 2
#
# 次の3つのどれかに当てはまれば、親にせず、子を親なしで起票する（action: no_parent）。どれにも当てはまらなければ親にする（action: use_as_parent）。
#   has_sub_issues     候補がサブ Issue を持つ（閉じた子も数える）
#   has_parent         候補が既に親を持つ（別のリポジトリの親も含む）
#   exceeds_max_depth  候補の下に紐付けた一番深い Issue が、設定の sub_issues.max_depth（既定 3）の層を超える
#                      深さは issue-create.sh の検査と同じく、候補から上へ issues/{番号}/parent をたどって数える（一番上の Issue が1層目。
#                      別のリポジトリの親もたどる）
#
# 出力: {issue, sub_issues（子の数）, parent（{number, repo} か null）, depth（紐付けた一番深い Issue の層）, max_depth,
#        has_sub_issues, has_parent, exceeds_max_depth, reasons（当てはまった条件の名前の配列。親にするなら []）,
#        action（use_as_parent か no_parent）}
# 候補が無い・PR の番号なら止まる（終了コード 1）。sub_issues.max_depth が 1・2・3 のどれでもなければ止まる（終了コード 2）。
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(CDPATH='' cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require gh jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

issue="" levels=1
while [ $# -gt 0 ]; do
  case "$1" in
    --issue | --levels)
      if [ $# -lt 2 ] || [ -z "$2" ]; then dw_die "$1 に値がありません" 64; fi
      if [ "$1" = --issue ]; then
        issue="$(dw_issue_number "$1" "$2")"
      else
        case "$2" in
          "" | *[!0-9]* | 0*) dw_die "--levels には 1 以上の整数を指定してください: $2" 64 ;;
        esac
        levels="$2"
      fi
      shift 2
      ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done
[ -n "$issue" ] || dw_die "--issue は必須です" 64

repo_nwo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
config="$("$BASH" "$DW_SCRIPTS_DIR/config.sh")"
# "2" のような文字列は認めないよう、JSON の形のまま比べる（issue-create.sh と同じ）
max_depth="$(jq -c '.sub_issues.max_depth' <<<"$config")"
case "$max_depth" in
  1 | 2 | 3) ;;
  *) dw_die "sub_issues.max_depth は 1・2・3 のどれかにしてください: $max_depth" 2 ;;
esac

candidate="$(dw_gh_find gh api "repos/$repo_nwo/issues/$issue" | jq -c 'if . == null or .pull_request then null else . end')"
[ "$candidate" != null ] || dw_die "親にする候補の Issue #${issue} がありません（${repo_nwo}）"
path="$(jq -r '.url | sub("^.*?/repos/"; "repos/")' <<<"$candidate")"

children="$(dw_sub_issues "$path")"
sub_count="$(jq 'length' <<<"$children")"

# 候補から上へたどり、候補が何層目かを数える（一番上の Issue が 1 層目）。親の親は別のリポジトリにあることもあるので、
# 応答の API の URL からパスを作る。GitHub の親子は8層までなので、念のため層の数で打ち切る
parent=null
own_depth=1
node="$candidate"
while [ "$own_depth" -lt 8 ]; do
  node="$(dw_gh_find gh api "repos/$(jq -r '.url | sub("^.*?/repos/"; "")' <<<"$node")/parent")"
  [ "$node" != null ] || break
  if [ "$parent" = null ]; then
    parent="$(jq -c '{number, repo: (.repository_url | sub("^.*/repos/"; ""))}' <<<"$node")"
  fi
  own_depth="$((own_depth + 1))"
done
depth="$((own_depth + levels))"

jq -n --argjson i "$issue" --argjson subs "$sub_count" --argjson parent "$parent" \
  --argjson depth "$depth" --argjson max "$max_depth" '
  {has_sub_issues: ($subs > 0), has_parent: ($parent != null), exceeds_max_depth: ($depth > $max)} as $c
  | ([$c | to_entries[] | select(.value) | .key]) as $reasons
  | {issue: $i, sub_issues: $subs, parent: $parent, depth: $depth, max_depth: $max} + $c
    + {reasons: $reasons, action: (if $reasons == [] then "use_as_parent" else "no_parent" end)}'
