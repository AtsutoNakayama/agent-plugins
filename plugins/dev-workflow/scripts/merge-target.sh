#!/usr/bin/env bash
# 今のブランチのマージ先を決め、origin から取得する（#284）。git の操作は fetch だけ（手元の origin/<マージ先> を更新する）。
# マージ先は、今のブランチの開いた PR があればその PR のマージ先（設定の base_branch と違うことがある。例：release/v1 に向いた PR）、
# 無ければ設定の base_branch。PR の選び方（fork の同じ名前のブランチからの PR は除く）と、マージ先が無い・空・git のブランチ名と
# して使えない値のときに設定の base_branch に戻すことは、dw_pr_pick（lib/common.sh）が決める。gh が無いか、失敗したか、
# JSON でない応答を返したときも、設定の base_branch を使う。
# スキルは、マージ先との差（git log <ref>..HEAD など）を読む前にこれを実行し、マージ先を自分で組み立てない。
#
# 使い方: merge-target.sh
#
# 取得できないとき:
#   origin/<マージ先> を取得できなければ、警告して手元の origin/<マージ先> を使う。手元にも無く、マージ先が PR のマージ先なら、
#   警告して設定の base_branch に戻す（同じく取得し、できなければ手元のものを使う）。どれも無ければ、終了コード 2 で止まる
#
# 出力（JSON）:
#   branch        今のブランチ（detached HEAD なら null）
#   base_branch   設定の base_branch
#   target        マージ先のブランチの名前
#   ref           マージ先の ref（origin/<target>）。git log <ref>..HEAD・git diff <ref>...HEAD のように使う
#   from          マージ先をどこから決めたか。pr（開いた PR のマージ先で、設定の base_branch と違う）・base_branch（設定の base_branch。
#                 PR が無い、PR のマージ先が base_branch と同じ、PR のマージ先を使えず base_branch に戻した、のどれか）
#   pr            今のブランチの開いた PR（number・url）。無いか、gh で読めなければ null
#   fetched       origin/<target> を今取得できたか（false なら手元の古いかもしれない origin/<target> を使った）
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(CDPATH='' cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require jq git

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done

repo_root="$(dw_repo_root)" || dw_die "リポジトリの中で実行してください" 64
config="$("$BASH" "$DW_SCRIPTS_DIR/config.sh")"
base_branch="$(dw_base_branch "$config")"
branch="$(git -C "$repo_root" symbolic-ref --short -q HEAD || true)"

target="$base_branch" from="base_branch" pr=null
if [ -n "$branch" ] && command -v gh >/dev/null 2>&1 \
  && prs="$(gh pr list --head "$branch" --state open --json number,url,baseRefName,isCrossRepository 2>/dev/null)" \
  && picked="$(dw_pr_pick "$prs" "$base_branch")"; then
  { IFS= read -r target; IFS= read -r pr; } <<<"$picked"
  if [ "$pr" != null ]; then
    pr="$(jq -c '{number, url}' <<<"$pr")"
    # PR のマージ先を読めずに base_branch に戻したときは、base_branch から決めたとする
    [ "$target" = "$base_branch" ] || from="pr"
  fi
fi

# origin/<名前> を取得する。取得できたら 0、できなくても手元にあれば警告して 1、手元にも無ければ 2 を返す
# 使い方: fetch_ref <ブランチ名>
fetch_ref() {
  git -C "$repo_root" fetch -q origin -- "$1" 2>/dev/null && return 0
  if git -C "$repo_root" rev-parse -q --verify "refs/remotes/origin/$1^{commit}" >/dev/null; then
    dw_warn "origin/${1} を最新にできませんでした。手元の origin/${1} で判断します"
    return 1
  fi
  return 2
}

fetched=true rc=0
fetch_ref "$target" || rc=$?
if [ "$rc" = 2 ] && [ "$from" = pr ]; then
  dw_warn "PR のマージ先の origin/${target} を取得できず、手元にもないので、設定の base_branch（${base_branch}）をマージ先にします"
  target="$base_branch" from="base_branch" rc=0
  fetch_ref "$target" || rc=$?
fi
[ "$rc" != 2 ] || dw_die "マージ先が見つかりません: origin/${target}（git fetch origin ${target} で取得してください）" 2
[ "$rc" = 0 ] || fetched=false

jq -n --arg branch "$branch" --arg base_branch "$base_branch" --arg target "$target" --arg from "$from" \
  --argjson pr "$pr" --argjson fetched "$fetched" \
  '{branch: (if $branch == "" then null else $branch end), base_branch: $base_branch, target: $target,
    ref: "origin/\($target)", from: $from, pr: $pr, fetched: $fetched}'
