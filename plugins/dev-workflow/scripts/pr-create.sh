#!/usr/bin/env bash
# 今のブランチを push し、Issue に紐付けた PR を作る。
# 何度実行しても同じ結果になる（そのブランチの開いた PR が既にあれば、push と（--check があれば）Issue のチェックだけを行い、
# その PR のタイトル・本文・ラベル・Project の列は変えない）。
#
# 使い方: pr-create.sh --issue N --body-file PATH [--title TEXT] [--check TEXT]... [--dry-run]
#   --issue N         紐付ける Issue の番号（#N でもよい）
#   --body-file PATH  PR の本文のファイル。- なら標準入力
#   --title TEXT      PR のタイトル。省略すると <Issue の type ラベル>: <Issue のタイトル>
#                     （Issue に breaking ラベルがあれば <type>!: <Issue のタイトル>）
#   --check TEXT      Issue の本文のチェックリストの、文が TEXT（出力の tasks の text）の項目にチェックを付ける。
#                     繰り返し指定できる。既にチェックがある項目は変えない。番号ではなく文で指すので、
#                     確かめた後に項目が増減しても、別の項目には付かない（その文の項目がちょうど1つでなければ止まる）
#   --dry-run         push も PR の作成も Issue のチェックもせず、行う予定の操作と PR のタイトル・本文、
#                     Issue のチェックリストの項目（tasks）を出力する
#
# 行うこと:
#   1. タイトルを設定の pr.title_pattern で検証する。type は Issue の type ラベルと同じにする。
#      Issue に breaking ラベルがあれば、type の後に ! が無いタイトルは止める
#   2. Issue に breaking ラベルがあれば、本文に BREAKING CHANGE: <移行のしかた> の行が無いと止める。
#      PR が既にあるときは、その PR のタイトルに ! が無い、または本文に BREAKING CHANGE が無いと、push の前に止める。
#      本文に <pr.close_keyword> #N（既定: Closes #N）が無ければ末尾に足す。
#      テンプレートの番号が空のままの行（Closes #）は消す
#   3. origin に push する（-u で追跡させる）。未コミットの変更や、PR にするコミットが無ければ止まる
#   4. base_branch に向けた PR を作り、Issue のラベルを引き継ぐ。pr.draft が true なら下書きにする
#   5. PR を新しく作ったときだけ、status.pr_opened が設定されていれば Issue をその列に移す（status-set.sh）。
#      既にある PR では移さない（手で先の列に移した Issue を戻さないため）
#   6. --check があれば、Issue の本文を読み直し、指定した文の項目だけにチェックを付ける（既にある PR のときも付ける）。
#      ほかの行は変えない。コードブロックと、行頭（字下げは問わない）の <!-- から --> までの HTML のコメントの中の行は、項目とみなさない
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

issue="" body_file="" title="" dry_run=false checks='[]'
while [ $# -gt 0 ]; do
  case "$1" in
    --issue | --body-file | --title | --check)
      need_value "$@"
      case "$1" in
        --issue) issue="$2" ;;
        --body-file) body_file="$2" ;;
        --title) title="$2" ;;
        --check) checks="$(jq -c --arg t "$2" '. + [$t] | unique' <<<"$checks")" ;;
      esac
      shift 2
      ;;
    --dry-run) dry_run=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done
[ -n "$issue" ] || dw_die "--issue は必須です" 64
# スキルの引数の #12 も受ける（dw_issue_number）
issue="$(dw_issue_number --issue "$issue")"
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
issue_json="$(gh issue view "$issue" --json number,title,state,labels,body)" || dw_die "Issue #${issue} を読めません"
labels="$(jq -c '[.labels[].name]' <<<"$issue_json")"
types="$(jq -c --argjson t "$(jq -c '.labels.types' <<<"$config")" 'map(select(. as $n | $t | index($n)))' <<<"$labels")"
[ "$(jq length <<<"$types")" = 1 ] \
  || dw_die "Issue #${issue} の type ラベルを1つにしてください（今は $(jq -r 'if length == 0 then "なし" else join(", ") end' <<<"$types")）" 2
type="$(jq -r '.[0]' <<<"$types")"
# GitHub と同じく、ラベルの名前は大文字と小文字を区別せずに照合する
breaking="$(jq --arg b "$DW_BREAKING_LABEL" 'any(.[]; ascii_downcase == $b)' <<<"$labels")"

# スカッシュのコミットの type に ! が無いと、release-please などが破壊的変更とみなさない
has_bang() { jq -e --arg s "$1" '$s | test("^[^:]*!:")' <<<null >/dev/null; }
# スカッシュマージでは PR の本文がコミットの本文になるので、移行のしかたを本文に残す
has_breaking_note() { jq -e --arg b "$1" '$b | test("(^|\n)BREAKING[ -]CHANGE: *\\S")' <<<null >/dev/null; }

# --- Issue のチェックリスト -----------------------------------------------------
# 本文のチェックリストの項目を、上から順に {line（0 からの行番号）, checked, text} で出す。
# GitHub と同じく、コードブロック（3つ以上の ` か ~ で囲む）の中の行は項目とみなさない。
# 閉じるのは、開いたときと同じ文字が同じ数以上並び、後ろが空白だけの行（中の短い囲みや ```js では閉じない）。
# ` の囲みの後ろに ` がある行（```x``` のようなインラインのコード）は囲みとみなさない。
# リストの中のコードブロックも拾うため、囲みの字下げは問わない。
# 複数行の HTML のコメント（行頭の <!-- から --> まで。囲みと同じく字下げは問わない）の中の行も、GitHub に表示されないので項目とみなさない。
# GitHub と同じく、行の途中の <!--（インラインのコードや項目の補足）はコメントの始まりとみなさない
# shellcheck disable=SC2016 # jq のプログラムなので、$ は展開しない
tasks_jq='
  def item: "^\\s*(?:[-*+]|[0-9]+[.)])\\s+\\[(?<c>[ xX])\\](?:\\s+(?<t>.*))?$";
  reduce (split("\n") | to_entries[]) as $e ({fence: null, comment: false, out: []};
    ($e.value | sub("\r$"; "")) as $l | .fence as $f
    | if .comment then
        (if $l | test("-->") then .comment = false else . end)
      elif $f != null then
        (if $l | test("^\\s*" + $f + "+\\s*$") then .fence = null else . end)
      elif $l | test("^\\s*(`{3,}[^`]*|~{3,}.*)$") then .fence = ($l | capture("^\\s*(?<f>`{3,}|~{3,})").f)
      elif $l | test("^\\s*<!--(?!.*-->)") then .comment = true
      elif $l | test(item) then
        ($l | capture(item)) as $m
        | .out += [{line: $e.key, checked: ($m.c != " "), text: ($m.t // "" | sub("\\s+$"; ""))}]
      else . end)
  | .out'
tasks="$(jq -c ".body // \"\" | $tasks_jq" <<<"$issue_json")"
# 文が1つの項目にだけ当たらない --check の文を出す（無い・複数ある）
# shellcheck disable=SC2016 # jq のプログラムなので、$ は展開しない
unmatched_jq='map(. as $s | select([$t[] | select(.text == $s)] | length != 1))'
unmatched="$(jq -c --argjson t "$tasks" "$unmatched_jq" <<<"$checks")"
[ "$unmatched" = '[]' ] \
  || dw_die "--check の文の項目が Issue #${issue} のチェックリストに1つだけではありません（無いか、同じ文が複数あります）: $(jq -r 'join(" / ")' <<<"$unmatched")" 64
# まだチェックの無い項目だけに付ける
to_check="$(jq -c --argjson t "$tasks" 'map(. as $s | select(any($t[]; .text == $s and (.checked | not))))' <<<"$checks")"

# --- 既にある PR ----------------------------------------------------------------
# --head はブランチ名だけで探すので、fork の同じ名前のブランチからの PR を除く
existing="$(gh pr list --head "$branch" --state open --json number,url,title,body,isCrossRepository \
  | jq -c 'map(select(.isCrossRepository | not))')" \
  || dw_die "${branch} の PR を取得できませんでした"
pr_number="$(jq -r '.[0].number // empty' <<<"$existing")"
pr_url="$(jq -r '.[0].url // empty' <<<"$existing")"
# 既にある PR のタイトルと本文は変えないので、PR を出した後に breaking ラベルを付けたときは、
# ! と BREAKING CHANGE の無いままマージされないよう、push の前に止める
if [ -n "$pr_number" ] && $breaking; then
  has_bang "$(jq -r '.[0].title' <<<"$existing")" \
    || dw_die "Issue #${issue} は破壊的変更（${DW_BREAKING_LABEL} ラベル）なのに、既にある PR #${pr_number} のタイトルの type の後に ! がありません（gh pr edit ${pr_number} --title で直してから実行してください）" 2
  has_breaking_note "$(jq -r '.[0].body' <<<"$existing")" \
    || dw_die "Issue #${issue} は破壊的変更（${DW_BREAKING_LABEL} ラベル）なのに、既にある PR #${pr_number} の本文に「BREAKING CHANGE: <移行のしかた>」がありません（gh pr edit ${pr_number} --body-file で直してから実行してください）" 2
fi

# --- 1. タイトル ----------------------------------------------------------------
[ -n "$title" ] || title="${type}$($breaking && echo '!'): $(jq -r .title <<<"$issue_json")"
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
if [ -z "$pr_number" ] && $breaking; then
  has_bang "$title" \
    || dw_die "Issue #${issue} は破壊的変更（${DW_BREAKING_LABEL} ラベル）なので、タイトルの type の後に ! を付けてください（${type}!: …）: $title" 2
fi

# --- 2. 本文 --------------------------------------------------------------------
if [ -z "$pr_number" ] && $breaking; then
  has_breaking_note "$body" \
    || dw_die "Issue #${issue} は破壊的変更（${DW_BREAKING_LABEL} ラベル）なので、本文の最後に「BREAKING CHANGE: <移行のしかた>」を書いてください" 64
fi
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
draft="$(jq -r '.pr.draft // false' <<<"$config")"
created=false
if [ -n "$pr_number" ]; then
  note "既にある PR #${pr_number} を使う（作り直さず、タイトル・本文・ラベル・列は変えない）"
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
if ! $created || [ -z "$(jq -r '.status.pr_opened // empty' <<<"$config")" ]; then
  status='{"skipped": true, "actions": []}'
elif [ -z "$(jq -r '.project.number // empty' <<<"$config")" ]; then
  dw_warn "project.number が未設定なので、Project の列は移しません（setup-project.sh --write-config で設定できます）"
  status='{"skipped": true, "actions": []}'
else
  status_args=(--issue "$issue" --to pr_opened)
  $dry_run && status_args+=(--dry-run)
  if ! status="$("$BASH" "$DW_SCRIPTS_DIR/status-set.sh" "${status_args[@]}")"; then
    $dry_run && dw_die "Issue #${issue} を列に移す予定を作れませんでした"
    # 次に実行しても PR は既にあるので列は移さない。移し方を伝える
    dw_die "PR #${pr_number} は作りましたが、Issue #${issue} の列を移せませんでした（status-set.sh --issue ${issue} --to pr_opened で移せます）"
  fi
fi
while IFS= read -r a; do
  [ -n "$a" ] && note "$a"
done <<<"$(jq -r '.actions[]?' <<<"$status")"

# --- 6. Issue のチェックリストにチェックを付ける --------------------------------
if [ "$(jq length <<<"$to_check")" -gt 0 ]; then
  note "Issue #${issue} のチェックリストの項目「$(jq -r 'join("」「")' <<<"$to_check")」にチェックを付ける"
  if ! $dry_run; then
    # 確かめた後に本文が変わっていてもよいよう、読み直した本文で、文が同じ項目を探して付ける
    # $( ) は末尾の改行を落とすので、本文は JSON のまま扱う
    now_json="$(gh issue view "$issue" --json body)" \
      || dw_die "PR #${pr_number} はできていますが、Issue #${issue} を読めず、チェックを付けられませんでした（もう一度実行すれば付けます）"
    now_tasks="$(jq -c ".body // \"\" | $tasks_jq" <<<"$now_json")"
    [ "$(jq -c --argjson t "$now_tasks" "$unmatched_jq" <<<"$to_check")" = '[]' ] \
      || dw_die "PR #${pr_number} はできていますが、Issue #${issue} の本文のチェックリストが途中で変わり、指定した文の項目が1つだけではなくなったので、チェックを付けませんでした（項目を確かめ直してから、もう一度実行してください）" 2
    # 指定した行の行頭のチェックボックスだけを [x] にし、項目の文の中の [ ] や、ほかの行（改行の \r を含む）はそのまま残す
    jq -j --argjson t "$now_tasks" --argjson c "$to_check" '
      ($t | map(select(.text as $s | $c | index($s))) | map(.line)) as $lines
      | .body // "" | split("\n") | to_entries
      | map(if .key as $k | $lines | index($k)
          then .value | sub("^(?<p>\\s*(?:[-*+]|[0-9]+[.)])\\s+)\\[ \\]"; "\(.p)[x]")
          else .value end)
      | join("\n")' <<<"$now_json" \
      | gh issue edit "$issue" --body-file - >/dev/null \
      || dw_die "PR #${pr_number} はできていますが、Issue #${issue} にチェックを付けられませんでした（もう一度実行すれば付けます）"
  fi
fi

jq -n --argjson i "$issue" --arg branch "$branch" --arg base "$base" --arg title "$title" --arg body "$body" \
  --argjson labels "$labels" --argjson breaking "$breaking" --argjson draft "$draft" --argjson created "$created" \
  --arg number "$pr_number" --arg url "$pr_url" --argjson status "$status" \
  --argjson tasks "$tasks" --argjson checked "$to_check" \
  --argjson dry "$dry_run" --argjson actions "$actions" '{
    issue: $i,
    dry_run: $dry,
    branch: $branch,
    base: $base,
    # 既にある PR には反映しないので、作るときだけ出す
    title: (if $created then $title else null end),
    body: (if $created then $body else null end),
    labels: (if $created then $labels else null end),
    breaking: $breaking,
    draft: $draft,
    created: $created,
    pr: (if $number == "" then null else {number: ($number | tonumber), url: $url} end),
    status: {from: ($status.from // null), to: ($status.to // null), skipped: ($status.skipped // false)},
    # Issue の本文のチェックリストの項目と、この実行でチェックを付ける項目の文
    tasks: ($tasks | map(del(.line))),
    checked: $checked,
    actions: $actions
  }'
