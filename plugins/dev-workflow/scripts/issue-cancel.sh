#!/usr/bin/env bash
# やらないことにした Issue を、理由のコメントを付けて not planned（重複なら duplicate）で閉じる。
#
# 使い方: issue-cancel.sh --issue N --reason TEXT [--duplicate-of M] [--branch NAME] [--sub-issues close|keep] [--dry-run]
#   --issue N           Issue の番号（#N でもよい）
#   --reason TEXT       閉じる理由（コメントとして残す。代わりに作業する Issue などの参照先も書く）。空白だけなら止まる
#   --duplicate-of M    重複の元の Issue の番号（#M でもよい）。付けると duplicate で閉じ、元の Issue に紐付ける（gh 2.88.0 以上）
#   --branch NAME       やめた作業のブランチ。そのブランチの開いている PR を同じ理由のコメントを付けて閉じ、
#                       リモート（origin）のブランチを削除する。手元のワークツリーとブランチは消さない（cleanup.sh --abandon）
#   --sub-issues MODE   親の Issue（サブ Issue を持つ Issue）を取りやめるときの、開いている子孫（子・孫）の扱い。
#                       close: 同じ理由をコメントして not planned で閉じる（深いものから順に、親より先に閉じる）
#                       keep:  閉じずに残す
#                       開いている子孫があるのに指定しなければ、何もせずに止まる。子孫の作業（PR・ブランチ）は片付けない
#                       （着手中の子は、先に子ごとに --branch を付けて取りやめる）。
#                       開いている子孫に別のリポジトリの Issue があれば、扱わずに止まる
#   --dry-run           変更せず、行う予定の操作だけを出力する
#
# Project からは外さず、Story Point も変えない（後からボードで経緯を参照できるように。設計書 §4）。
# （--sub-issues close なら開いている子孫 →）Issue → PR → リモートのブランチの順に行う。何度実行しても同じ結果になるので、途中で失敗しても再実行で続きから進む。
# 最後のコメントが同じ理由ならコメントを付け直さず、同じ閉じ方で既に閉じていれば閉じる操作を飛ばす。
# 違う閉じ方や違う理由で既に閉じている Issue では、何もせずに止まる。
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require gh jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

# オプションの値を取り出す。無ければ使い方の誤り（64）で終了する
need_value() {
  if [ $# -lt 2 ] || [ -z "$2" ]; then
    dw_die "$1 に値がありません" 64
  fi
}

issue="" reason="" duplicate_of="" branch="" sub_issues="" dry_run=false
while [ $# -gt 0 ]; do
  case "$1" in
    --issue | --reason | --duplicate-of | --branch | --sub-issues)
      need_value "$@"
      case "$1" in
        --issue) issue="$2" ;;
        --reason) reason="$2" ;;
        --duplicate-of) duplicate_of="$2" ;;
        --branch) branch="$2" ;;
        --sub-issues)
          case "$2" in
            close | keep) sub_issues="$2" ;;
            *) dw_die "--sub-issues には close か keep を指定してください: $2" 64 ;;
          esac
          ;;
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
# # だけを渡されて番号が空のまま not planned で閉じないよう、dw_issue_number が拒否する
[ -z "$duplicate_of" ] || duplicate_of="$(dw_issue_number --duplicate-of "$duplicate_of")"
# どちらも先頭の 0 をそろえてあるので、文字列で比べられる（017 と 17 は同じ Issue）
if [ -n "$duplicate_of" ] && [ "$duplicate_of" = "$issue" ]; then
  dw_die "--duplicate-of に閉じる Issue 自身（#${issue}）は指定できません" 64
fi
# 理由の無いまま閉じると経緯が残らないので、空白だけの理由も受け付けない。
# tr はバイト単位で消すので、日本語の入力でよく入る全角スペース（U+3000）は先に取り除く
fullwidth_space="$(printf '\343\200\200')"
stripped="${reason//"$fullwidth_space"/}"
[ -n "$(printf '%s' "$stripped" | tr -d '[:space:]')" ] || dw_die "--reason に閉じる理由を書いてください" 64

if [ -n "$duplicate_of" ]; then
  state_reason=DUPLICATE
  dw_require_gh_version "$DW_GH_MIN_VERSION" "重複として閉じる（gh issue close --duplicate-of）"
else
  state_reason=NOT_PLANNED
fi

if [ -n "$branch" ]; then
  base="$("$BASH" "$DW_SCRIPTS_DIR/config.sh" | jq -r '.base_branch // "main"')"
  [ "$branch" != "$base" ] || dw_die "${base} は削除できません。--branch で作業用のブランチを指定してください" 64
fi

repo_nwo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"

# gh issue view は PR の番号でも成功するので、dw_read_issue で PR を見分けて止まる
found="$(dw_read_issue "$issue" number,title,state,stateReason,comments)"
[ -z "$duplicate_of" ] || dw_read_issue "$duplicate_of" number "重複の元の Issue" >/dev/null

# コメントした後に閉じるのに失敗して再実行したときは、同じ理由を二重にコメントしない
commented=true
if jq -e --arg r "$reason" '.comments[-1].body == $r' <<<"$found" >/dev/null; then
  commented=false
fi
closed=true
if [ "$(jq -r .state <<<"$found")" != OPEN ]; then
  # 同じ閉じ方・同じ理由で閉じていれば、前回の実行の続きとして閉じる操作を飛ばす
  if [ "$(jq -r .stateReason <<<"$found")" = "$state_reason" ] && ! $commented; then
    closed=false
  else
    dw_die "Issue #${issue} は既に閉じています" 2
  fi
fi

# 開いている子孫（サブ Issue とその下）。浅いものから順に読み、閉じるときは深いものから閉じる
# （子を残したまま親が閉じた状態にしない）。子は GitHub の画面で別のリポジトリの Issue も紐付けられるので、
# たどるパスはホストによらない API の url（.../repos/OWNER/NAME/issues/N）から、子のリポジトリは repository_url から取る
# 使い方: sub_issues_of <repos/OWNER/NAME/issues/N> → 子の配列
sub_issues_of() {
  gh api --paginate "$1/sub_issues?per_page=100" | jq -sc 'add // []' \
    || dw_die "#${1##*/} のサブ Issue を読めませんでした"
}
open_subs='[]'
level="$(sub_issues_of "repos/$repo_nwo/issues/$issue")"
# GitHub の親子は8層まで。循環は作れないが、念のため層の数で打ち切る
depth=0
while [ "$(jq length <<<"$level")" -gt 0 ] && [ "$depth" -lt 8 ]; do
  depth=$((depth + 1))
  open_subs="$(jq -c --argjson l "$level" '. + ($l | map(select(.state == "open")
    | {number, title, repo: (.repository_url | sub("^.*/repos/"; ""))}))' <<<"$open_subs")"
  next='[]'
  # 孫の数（sub_issues_summary）が応答に無ければ、孫を見落とさないよう読みにいく
  for path in $(jq -r '.[] | select((.sub_issues_summary.total // 1) > 0) | .url | sub("^.*?/repos/"; "repos/")' <<<"$level"); do
    children="$(sub_issues_of "$path")"
    next="$(jq -c --argjson c "$children" '. + $c' <<<"$next")"
  done
  level="$next"
done
# 別のリポジトリの子孫は扱わない（このプラグインが起票する子は親と同じリポジトリだけ。設計書 §4）。
# Issue も PR もブランチもそのリポジトリにあり、ここでは片付けきれないので、何もせずに止まる
foreign="$(jq -r --arg nwo "$repo_nwo" 'map(select(.repo != $nwo) | "\(.repo)#\(.number)") | join(", ")' <<<"$open_subs")"
[ -z "$foreign" ] \
  || dw_die "Issue #${issue} の開いている子孫に、別のリポジトリの Issue（${foreign}）があります。その Issue を親から外すか、そのリポジトリで取りやめてから、もう一度実行してください" 2
open_subs="$(jq -c 'map({number, title})' <<<"$open_subs")"
if [ "$(jq length <<<"$open_subs")" -gt 0 ] && [ -z "$sub_issues" ]; then
  dw_die "Issue #${issue} には開いている子の Issue（$(jq -r 'map("#\(.number)") | join(", ")' <<<"$open_subs")）があります。--sub-issues で、一緒に閉じる（close）か残す（keep）かを指定してください" 2
fi
if [ "$sub_issues" = close ]; then
  # 閉じるのに失敗して再実行したときに、同じ理由を二重にコメントしないよう、子ごとに最後のコメントを見る
  with_comment='[]'
  for n in $(jq -r '.[].number' <<<"$open_subs"); do
    # $( ) は末尾の改行を落とすので、最後のコメントは取り出さずに jq の中で理由と比べる（親や PR と同じ）
    child="$(gh issue view "$n" --json comments)" || dw_die "子の Issue #${n} を読めませんでした"
    with_comment="$(jq -c --argjson n "$n" --argjson child "$child" --arg r "$reason" \
      '. + [{number: $n, commented: ($child.comments[-1].body != $r)}]' <<<"$with_comment")"
  done
  open_subs="$(jq -c --argjson w "$with_comment" 'map(. as $s | . + ($w[] | select(.number == $s.number) | {commented}))' <<<"$open_subs")"
fi

# やめた作業のリモートのブランチ（無ければ空）と、それを head とする開いている PR
remote="" prs='[]'
if [ -n "$branch" ]; then
  if err="$(gh api "repos/$repo_nwo/git/ref/heads/$branch" 2>&1 >/dev/null)"; then
    remote="$branch"
  else
    case "$err" in
      *"HTTP 404"*) ;;
      *) dw_die "リモートのブランチ ${branch} を確かめられませんでした: $err" ;;
    esac
  fi
  prs="$(gh pr list --head "$branch" --state open --json number,title,url,isCrossRepository,comments)" \
    || dw_die "${branch} の PR を取得できませんでした"
  # --head はブランチ名でしか絞れないので、ほかの人の fork の同じ名前のブランチから出た PR を除く
  prs="$(jq -c --arg r "$reason" 'map(select(.isCrossRepository | not)
    | {number, title, url, commented: (.comments[-1].body != $r)})' <<<"$prs")"
fi

actions='[]'
note() { actions="$(jq -c --arg a "$1" '. + [$a]' <<<"$actions")"; }

if [ "$sub_issues" = close ]; then
  # 浅い順に読んだので、逆にたどって深いものから閉じる
  for n in $(jq -r 'reverse | .[].number' <<<"$open_subs"); do
    if [ "$(jq -r --argjson n "$n" '.[] | select(.number == $n) | .commented' <<<"$open_subs")" = true ]; then
      note "子の Issue #${n} に閉じる理由をコメントする"
      if ! $dry_run; then
        printf '%s' "$reason" | gh issue comment "$n" --body-file - >/dev/null \
          || dw_die "子の Issue #${n} にコメントできませんでした（もう一度実行すると続きから進みます）"
      fi
    fi
    note "子の Issue #${n} を not planned で閉じる（Project と Story Point はそのまま残す）"
    $dry_run || gh issue close "$n" --reason "not planned" >/dev/null 2>&1 \
      || dw_die "子の Issue #${n} を閉じられませんでした（もう一度実行すると続きから進みます）"
  done
fi

if $commented; then
  note "Issue #${issue} に閉じる理由をコメントする"
  if ! $dry_run; then
    printf '%s' "$reason" | gh issue comment "$issue" --body-file - >/dev/null \
      || dw_die "Issue #${issue} にコメントできませんでした"
  fi
fi
if $closed; then
  if [ -n "$duplicate_of" ]; then
    note "Issue #${issue} を #${duplicate_of} の重複（duplicate）として閉じる（Project と Story Point はそのまま残す）"
  else
    note "Issue #${issue} を not planned で閉じる（Project と Story Point はそのまま残す）"
  fi
  if ! $dry_run; then
    if [ -n "$duplicate_of" ]; then
      gh issue close "$issue" --duplicate-of "$duplicate_of" >/dev/null 2>&1
    else
      gh issue close "$issue" --reason "not planned" >/dev/null 2>&1
    fi || dw_die "Issue #${issue} にコメントしましたが、閉じられませんでした（もう一度実行すると、コメントを付け直さずに閉じます）"
  fi
fi

for pr_number in $(jq -r '.[].number' <<<"$prs"); do
  if [ "$(jq -r --argjson n "$pr_number" '.[] | select(.number == $n) | .commented' <<<"$prs")" = true ]; then
    note "PR #${pr_number} に閉じる理由をコメントする"
    if ! $dry_run; then
      printf '%s' "$reason" | gh pr comment "$pr_number" --body-file - >/dev/null \
        || dw_die "Issue #${issue} は閉じましたが、PR #${pr_number} にコメントできませんでした（もう一度実行すると続きから進みます）"
    fi
  fi
  note "PR #${pr_number} をマージせずに閉じる"
  # --delete-branch は手元のブランチも消し、ワークツリーで使っていると失敗するので、リモートのブランチは下で消す
  $dry_run || gh pr close "$pr_number" >/dev/null 2>&1 \
    || dw_die "Issue #${issue} は閉じましたが、PR #${pr_number} を閉じられませんでした（もう一度実行すると続きから進みます）"
done
if [ -n "$remote" ]; then
  note "リモートのブランチ ${branch} を削除する"
  $dry_run || gh api -X DELETE "repos/$repo_nwo/git/refs/heads/$branch" >/dev/null 2>&1 \
    || dw_die "Issue #${issue} は閉じましたが、リモートのブランチ ${branch} を削除できませんでした（もう一度実行すると続きから進みます）"
fi

jq -n --argjson found "$found" --argjson dry "$dry_run" --arg reason "$reason" --arg sr "$state_reason" \
  --arg dup "$duplicate_of" --argjson commented "$commented" --argjson closed "$closed" --argjson actions "$actions" \
  --arg branch "$branch" --arg remote "$remote" --argjson prs "$prs" \
  --arg subs_mode "$sub_issues" --argjson subs "$open_subs" '{
    issue: $found.number,
    title: $found.title,
    dry_run: $dry,
    state_reason: $sr,
    duplicate_of: (if $dup == "" then null else ($dup | tonumber) end),
    comment: $reason,
    commented: $commented,
    closed: $closed,
    branch: (if $branch == "" then null else $branch end),
    pull_requests: $prs,
    remote_branch_deleted: ($remote != ""),
    sub_issues: {action: (if $subs_mode == "" then null else $subs_mode end), open: $subs},
    actions: $actions
  }'
