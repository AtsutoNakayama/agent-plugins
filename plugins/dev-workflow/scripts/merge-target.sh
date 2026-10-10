#!/usr/bin/env bash
# 今のブランチのマージ先を決め、origin から取得する（#284）。git の操作は fetch だけ（手元の origin/<マージ先> を更新する）。
# 読むだけの処理（pr-create の手順2・task-auto の確認で、マージ先との差を読む）が使う。スキルは、マージ先を自分で組み立てない。
# マージ先は、今のブランチの開いた PR があればその PR のマージ先（設定の base_branch と違うことがある。例：release/v1 に向いた PR）、
# 無ければ設定の base_branch。PR のマージ先を使えないときの規則（fallback）は lib/common.sh の「PR のマージ先」が正本で、
# このスクリプトは読むだけの側なので、警告して続ける（スキルは fallback が null でなければ、その旨を伝える）。
# 本体は lib/common.sh の dw_merge_target（review-perspectives.sh --auto も同じものを使う）。
#
# 使い方: merge-target.sh
#
# 出力（JSON）:
#   branch        今のブランチ（detached HEAD なら null）
#   base_branch   設定の base_branch
#   target        マージ先のブランチの名前
#   ref           マージ先の ref（origin/<target>）。git log <ref>..HEAD・git diff <ref>...HEAD のように使う
#   from          マージ先をどこから決めたか。pr（開いた PR の baseRefName をそのまま使った。base_branch と同じ値でも pr）・
#                 base_branch（PR が無い、PR の baseRefName が無いか空、使えずに base_branch に戻した）
#   pr            今のブランチの開いた PR（number・url）。無いか、gh で読めなければ null
#   fallback      PR のマージ先をそのまま使えなかった理由。null・invalid_name（ブランチ名として使えない。target は base_branch）・
#                 multiple_prs（マージ先の違う開いた PR が複数ある。target は最初の PR のもの）・fetch_failed（取得できず手元にも
#                 無い。target は base_branch）
#   fetched       origin/<target> を今取得できたか（false なら、手元の古いかもしれない origin/<target> を使った）
#
# origin/<base_branch> も取得できず手元にも無ければ、終了コード 2 で止まる
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
config="$("$BASH" "$DW_SCRIPTS_DIR/config.sh")" || dw_die "設定を読めません（config.sh で確かめてください）" 2
base_branch="$(dw_base_branch "$config")"
branch="$(git -C "$repo_root" symbolic-ref --short -q HEAD || true)"
dw_merge_target "$repo_root" "$base_branch" "$branch"
