#!/usr/bin/env bash
# PR がマージされた後の後片付け。マージを確かめてから、ワークツリーとローカルのブランチを削除し、
# マージ先のブランチ（base_branch）を最新にする。
# 何度実行しても同じ結果になる（既に無いワークツリー・ブランチは飛ばす）。
#
# 使い方: cleanup.sh [--branch NAME] [--dry-run]
#   --branch NAME   片付けるブランチ。省略すると今のブランチ
#   --dry-run       変更せず、行う予定の操作だけを出力する
#
# 行うこと:
#   1. そのブランチの PR がマージされたかを確かめる。PR に入っていないコミットがあれば止まる
#      （スカッシュマージでは git branch -d が使えないので、PR の最後のコミットと比べる）
#   2. ワークツリーを削除する。未コミットの変更（サブモジュールの中も含む）や、
#      サブモジュールにリモートに無いコミット・stash があれば止まる。
#      メインのワークツリーでそのブランチを使っていたら、削除せずに base_branch に切り替える
#   3. ローカルのブランチを削除する（git branch -D）
#   4. base_branch を最新にする（git pull --ff-only に当たる。fetch --prune の後、早送りだけで取り込む）
#
# 削除するワークツリーの中から実行すると、実行後にその場所が無くなる。メインのワークツリー（main_root）で実行する。
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require gh jq git

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

# オプションの値を取り出す。無ければ使い方の誤り（64）で終了する
need_value() {
  if [ $# -lt 2 ] || [ -z "$2" ]; then
    dw_die "$1 に値がありません" 64
  fi
}

branch="" dry_run=false
while [ $# -gt 0 ]; do
  case "$1" in
    --branch)
      need_value "$@"
      branch="$2"
      shift 2
      ;;
    --dry-run) dry_run=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done

repo_root="$(dw_repo_root)" || dw_die "リポジトリの中で実行してください" 64
main_root="$(dw_main_root "$repo_root")" || dw_die "メインのワークツリーが分かりません"
config="$("$BASH" "$DW_SCRIPTS_DIR/config.sh")"
base="$(jq -r '.base_branch' <<<"$config")"

if [ -z "$branch" ]; then
  branch="$(git -C "$repo_root" symbolic-ref --short -q HEAD || true)"
  [ -n "$branch" ] || dw_die "ブランチの上にいません。--branch で指定してください" 64
fi
[ "$branch" != "$base" ] || dw_die "${base} は片付けられません。--branch で作業用のブランチを指定してください" 64

actions='[]'
note() { actions="$(jq -c --arg a "$1" '. + [$a]' <<<"$actions")"; }

# ブランチを使っているワークツリーの場所（無ければ空）
worktree_of() {
  git -C "$main_root" worktree list --porcelain \
    | awk -v b="refs/heads/$1" '/^worktree /{p=substr($0, 10)} $0 == "branch " b {print p}'
}

# --- 1. マージの確認 ------------------------------------------------------------
prs="$(gh pr list --head "$branch" --state all --json number,url,state,mergedAt,headRefOid,baseRefName)" \
  || dw_die "${branch} の PR を取得できませんでした"
pr="$(jq -c 'map(select(.state == "MERGED")) | sort_by(.mergedAt) | last // empty' <<<"$prs")"
if [ -z "$pr" ]; then
  open="$(jq -r 'map(select(.state == "OPEN")) | .[0].number // empty' <<<"$prs")"
  [ -z "$open" ] || dw_die "PR #${open} はまだマージされていません" 2
  dw_die "${branch} のマージされた PR がありません" 2
fi
pr_number="$(jq -r .number <<<"$pr")"
head_oid="$(jq -r .headRefOid <<<"$pr")"

has_branch=false
git -C "$main_root" show-ref --verify --quiet "refs/heads/$branch" && has_branch=true
if $has_branch; then
  tip="$(git -C "$main_root" rev-parse "refs/heads/$branch")"
  if [ "$tip" != "$head_oid" ]; then
    # PR の最後のコミットが手元に無ければ、GitHub が残している refs/pull/<番号>/head から取る
    git -C "$main_root" cat-file -e "${head_oid}^{commit}" 2>/dev/null \
      || git -C "$main_root" fetch -q origin "refs/pull/$pr_number/head" 2>/dev/null \
      || dw_die "PR #${pr_number} の最後のコミット ${head_oid} を取得できません"
    git -C "$main_root" merge-base --is-ancestor "$tip" "$head_oid" \
      || dw_die "${branch} に PR #${pr_number} に入っていないコミットがあります（push していない作業が無いか確かめてください）" 2
  fi
fi

# --- 2. ワークツリー ------------------------------------------------------------
path="$(worktree_of "$branch")"
worktree_removed=false switched=false
# ディレクトリを手で消すと、git の記録だけが残る。記録を片付ける
if [ -n "$path" ] && [ ! -d "$path" ]; then
  note "消えたワークツリー $path の記録を片付ける（git worktree prune）"
  $dry_run || git -C "$main_root" worktree prune
  path=""
fi
if [ -n "$path" ]; then
  # サブモジュールの中の変更も見る（submodule.<name>.ignore などの設定で隠されないよう none を指定する）
  [ -z "$(git -C "$path" status --porcelain --ignore-submodules=none)" ] \
    || dw_die "$path に未コミットの変更があります。コミットするか片付けてから実行してください" 2
  if [ "$path" = "$main_root" ]; then
    switched=true
    note "メインのワークツリーを ${branch} から ${base} に切り替える"
    $dry_run || git -C "$main_root" switch -q "$base" || dw_die "${base} に切り替えられませんでした"
  else
    # サブモジュールの git のデータはワークツリーと一緒に消えるので、リモートに無いコミット（HEAD とローカルのブランチ）や
    # stash が残っていれば止まる。リモートのブランチかタグ（タグは手元のものとリモートのものを区別できない）から届かない
    # コミットは、SHA で取ってきた push 済みのものでも手元では見分けられないので、安全のために止まる
    # shellcheck disable=SC2016 # 各サブモジュールの中で展開させる
    unpushed="$(git -C "$path" submodule --quiet foreach --recursive '
      if [ -n "$(git log -1 --format=%h HEAD --branches --not --remotes --tags)" ] \
        || git rev-parse -q --verify refs/stash >/dev/null; then
        echo "$displaypath"
      fi')" || dw_die "$path のサブモジュールを確かめられませんでした"
    [ -z "$unpushed" ] \
      || dw_die "$path のサブモジュール（${unpushed//$'\n'/, }）に、リモートに無いコミットか stash があります。push するか片付けてから実行してください" 2
    worktree_removed=true
    note "ワークツリー $path を削除する"
    # サブモジュールを初期化したワークツリーは --force が無いと削除できない。変更が無いことは上で確かめた
    $dry_run || git -C "$main_root" worktree remove --force "$path" || dw_die "ワークツリー $path を削除できませんでした"
  fi
fi

# --- 3. ブランチ ----------------------------------------------------------------
branch_deleted=false
if $has_branch; then
  branch_deleted=true
  note "ローカルのブランチ ${branch} を削除する"
  $dry_run || git -C "$main_root" branch -q -D "$branch" >/dev/null || dw_die "ブランチ ${branch} を削除できませんでした"
fi

# --- 4. base_branch を最新にする -------------------------------------------------
from="$(git -C "$main_root" rev-parse -q --verify "refs/heads/$base" || true)"
base_path="$(worktree_of "$base")"
# 切り替えた後はメインのワークツリーが base_branch を使う（dry-run では切り替えていない）
$switched && base_path="$main_root"
if [ -n "$base_path" ]; then
  note "${base_path} の ${base} に origin/${base} を早送りで取り込む（git pull --ff-only）"
else
  note "${base} を origin/${base} まで早送りする"
fi
to="$from"
if ! $dry_run; then
  git -C "$main_root" fetch -q --prune origin || dw_die "origin を取得できませんでした"
  if [ -n "$base_path" ]; then
    git -C "$base_path" merge -q --ff-only "origin/$base" \
      || dw_die "${base} を早送りで最新にできません（${base} に origin に無いコミットがあるか、未コミットの変更とぶつかります）"
  else
    git -C "$main_root" fetch -q origin "$base:$base" \
      || dw_die "${base} を早送りで最新にできません（${base} に origin に無いコミットがあります）"
  fi
  to="$(git -C "$main_root" rev-parse "refs/heads/$base")"
fi

jq -n --arg branch "$branch" --arg path "$path" --arg main "$main_root" --arg base "$base" \
  --argjson pr "$pr" --argjson wr "$worktree_removed" --argjson sw "$switched" --argjson bd "$branch_deleted" \
  --arg from "$from" --arg to "$to" --argjson dry "$dry_run" --argjson actions "$actions" '{
    branch: $branch,
    dry_run: $dry,
    pr: {number: $pr.number, url: $pr.url, merged_at: $pr.mergedAt},
    worktree: (if $path == "" then null else $path end),
    main_root: $main,
    removed: {worktree: $wr, branch: $bd},
    switched: $sw,
    base: {name: $base, from: (if $from == "" then null else $from end), to: (if $to == "" then null else $to end)},
    actions: $actions
  }'
