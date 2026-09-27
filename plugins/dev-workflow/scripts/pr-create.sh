#!/usr/bin/env bash
# 今のブランチを push し、Issue に紐付けた PR を作る。
# 何度実行しても同じ結果になる（そのブランチの開いた PR が既にあれば、push だけして作り直さない）。
#
# 使い方: pr-create.sh --issue N --body-file PATH [--title TEXT] [--dry-run]
#   --issue N         紐付ける Issue の番号
#   --body-file PATH  PR の本文のファイル。- なら標準入力
#   --title TEXT      PR のタイトル。省略すると <Issue の type ラベル>: <Issue のタイトル>
#   --dry-run         push も PR の作成もせず、行う予定の操作と PR のタイトル・本文だけを出力する
#
# 行うこと:
#   1. タイトルを設定の pr.title_pattern で検証する。type は Issue の type ラベルと同じにする
#   2. 本文に <pr.close_keyword> #N（既定: Closes #N）が無ければ末尾に足す。
#      テンプレートの番号が空のままの行（Closes #）は消す
#   3. origin に push する（-u で追跡させる）。未コミットの変更や、PR にするコミットが無ければ止まる
#   4. base_branch に向けた PR を作り、Issue のラベルを引き継ぐ。pr.draft が true なら下書きにする
#   5. status.pr_opened が設定されていれば、Issue をその列に移す（status-set.sh）
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

issue="" body_file="" title="" dry_run=false
while [ $# -gt 0 ]; do
  case "$1" in
    --issue | --body-file | --title)
      need_value "$@"
      case "$1" in
        --issue) issue="$2" ;;
        --body-file) body_file="$2" ;;
        --title) title="$2" ;;
      esac
      shift 2
      ;;
    --dry-run) dry_run=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done
[ -n "$issue" ] || dw_die "--issue は必須です" 64
case "$issue" in
  *[!0-9]*) dw_die "--issue には数字を指定してください: $issue" 64 ;;
esac
[ -n "$body_file" ] || dw_die "--body-file は必須です" 64
if [ "$body_file" = - ]; then
  body="$(cat)"
else
  [ -f "$body_file" ] || dw_die "本文のファイルがありません: $body_file" 64
  body="$(cat "$body_file")"
fi

repo_root="$(dw_repo_root)" || dw_die "リポジトリの中で実行してください" 64
config="$("$BASH" "$DW_SCRIPTS_DIR/config.sh")"
base="$(jq -r '.base_branch' <<<"$config")"

actions='[]'
note() { actions="$(jq -c --arg a "$1" '. + [$a]' <<<"$actions")"; }

# --- ブランチと変更の確認 -------------------------------------------------------
branch="$(git -C "$repo_root" symbolic-ref --short -q HEAD || true)"
[ -n "$branch" ] || dw_die "ブランチの上にいません（detached HEAD）" 2
[ "$branch" != "$base" ] || dw_die "${base} からは PR を作りません。作業用のブランチで実行してください（task-start）" 2
[ -z "$(git -C "$repo_root" status --porcelain --untracked-files=no)" ] \
  || dw_die "未コミットの変更があります。コミットしてから実行してください（commit）" 2

# --- Issue ----------------------------------------------------------------------
issue_json="$(gh issue view "$issue" --json number,title,state,labels)" || dw_die "Issue #${issue} を読めません"
labels="$(jq -c '[.labels[].name]' <<<"$issue_json")"
types="$(jq -c --argjson t "$(jq -c '.labels.types' <<<"$config")" 'map(select(. as $n | $t | index($n)))' <<<"$labels")"
[ "$(jq length <<<"$types")" = 1 ] \
  || dw_die "Issue #${issue} の type ラベルを1つにしてください（今は $(jq -r 'if length == 0 then "なし" else join(", ") end' <<<"$types")）" 2
type="$(jq -r '.[0]' <<<"$types")"

# --- 1. タイトル ----------------------------------------------------------------
[ -n "$title" ] || title="${type}: $(jq -r .title <<<"$issue_json")"
case "$title" in
  *$'\n'*) dw_die "タイトルは1行にしてください" 64 ;;
esac
pattern="$(jq -r '.pr.title_pattern' <<<"$config")"
jq -e --arg s "$title" --arg p "$pattern" '$s | test($p)' <<<null >/dev/null \
  || dw_die "タイトルが規約に合いません（<type>: <Issue のタイトル>）: $title" 2
# type ラベル・ブランチ名・PR のタイトルは同じ type で1対1に対応させる（設計書 §5）
title_type="$(jq -rn --arg s "$title" '$s | capture("^(?<t>[a-z]+)").t // ""')"
[ "$title_type" = "$type" ] \
  || dw_die "タイトルの type（${title_type}）が Issue #${issue} の type ラベル（${type}）と違います" 2

# --- 2. 本文 --------------------------------------------------------------------
keyword="$(jq -r '.pr.close_keyword' <<<"$config")"
body="$(jq -rn --arg b "$body" --arg k "$keyword" --arg n "$issue" '
  # テンプレートの番号が空のままの行（Closes #）を消し、末尾の空行を落とす
  ($b | split("\n") | map(select(test("^\\s*" + $k + "\\s+#\\s*$"; "i") | not)) | join("\n")
    | sub("\\s+$"; "")) as $body
  | if $body | test("\\b" + $k + "\\s+#" + $n + "\\b"; "i") then $body
    elif $body == "" then "\($k) #\($n)"
    else "\($body)\n\n\($k) #\($n)" end')"
[ "$body" != "$keyword #$issue" ] || dw_die "本文が空です（概要・変更点・確認方法を書いてください）" 64

# --- 3. push --------------------------------------------------------------------
if ! $dry_run; then
  git -C "$repo_root" fetch -q origin "$base" || dw_die "origin/${base} を取得できませんでした"
fi
git -C "$repo_root" rev-parse -q --verify "refs/remotes/origin/$base" >/dev/null \
  || dw_die "origin/${base} がありません（git fetch origin ${base} を実行してください）"
ahead="$(git -C "$repo_root" rev-list --count "origin/$base..HEAD")"
[ "$ahead" -gt 0 ] || dw_die "origin/${base} に無いコミットがありません。PR にする変更をコミットしてください" 2

note "${branch} を origin に push する（origin/${base} より ${ahead} 個先のコミット）"
if ! $dry_run; then
  # 出力は JSON だけにするため、git の出力は標準エラーに回す
  git -C "$repo_root" push -q -u origin "$branch" >&2 \
    || dw_die "${branch} を push できませんでした（origin/${branch} に手元に無いコミットがあれば、取り込んでからやり直してください）"
fi

# --- 4. PR ----------------------------------------------------------------------
existing="$(gh pr list --head "$branch" --state open --json number,url)" \
  || dw_die "${branch} の PR を取得できませんでした"
pr_number="$(jq -r '.[0].number // empty' <<<"$existing")"
pr_url="$(jq -r '.[0].url // empty' <<<"$existing")"
draft="$(jq -r '.pr.draft // false' <<<"$config")"
created=false
if [ -n "$pr_number" ]; then
  note "既にある PR #${pr_number} を使う（作り直さない）"
else
  created=true
  note "${base} に向けた PR「${title}」を作る$($draft && echo '（下書き）')"
  [ "$(jq length <<<"$labels")" = 0 ] || note "PR にラベル $(jq -r 'join(", ")' <<<"$labels") を付ける"
  if ! $dry_run; then
    body_tmp="$(mktemp)"
    trap 'rm -f "$body_tmp"' EXIT
    printf '%s\n' "$body" >"$body_tmp"
    pr_args=(--base "$base" --head "$branch" --title "$title" --body-file "$body_tmp")
    $draft && pr_args+=(--draft)
    while IFS= read -r l; do
      [ -n "$l" ] && pr_args+=(--label "$l")
    done <<<"$(jq -r '.[]' <<<"$labels")"
    pr_url="$(gh pr create "${pr_args[@]}" | tail -n 1)" || dw_die "${branch} は push しましたが、PR を作れませんでした"
    pr_number="${pr_url##*/}"
  fi
fi

# --- 5. pr_opened の列に移す ----------------------------------------------------
if [ -z "$(jq -r '.status.pr_opened // empty' <<<"$config")" ]; then
  status='{"skipped": true, "actions": []}'
elif [ -z "$(jq -r '.project.number // empty' <<<"$config")" ]; then
  dw_warn "project.number が未設定なので、Project の列は移しません（setup-project.sh --write-config で設定できます）"
  status='{"skipped": true, "actions": []}'
else
  status_args=(--issue "$issue" --to pr_opened)
  $dry_run && status_args+=(--dry-run)
  status="$("$BASH" "$DW_SCRIPTS_DIR/status-set.sh" "${status_args[@]}")" \
    || dw_die "PR #${pr_number:-?} は作りましたが、Issue #${issue} の列を移せませんでした"
fi
while IFS= read -r a; do
  [ -n "$a" ] && note "$a"
done <<<"$(jq -r '.actions[]?' <<<"$status")"

jq -n --argjson i "$issue" --arg branch "$branch" --arg base "$base" --arg title "$title" --arg body "$body" \
  --argjson labels "$labels" --argjson draft "$draft" --argjson created "$created" \
  --arg number "$pr_number" --arg url "$pr_url" --argjson status "$status" \
  --argjson dry "$dry_run" --argjson actions "$actions" '{
    issue: $i,
    dry_run: $dry,
    branch: $branch,
    base: $base,
    title: $title,
    body: $body,
    labels: $labels,
    draft: $draft,
    created: $created,
    pr: (if $number == "" then null else {number: ($number | tonumber), url: $url} end),
    status: {from: ($status.from // null), to: ($status.to // null), skipped: ($status.skipped // false)},
    actions: $actions
  }'
