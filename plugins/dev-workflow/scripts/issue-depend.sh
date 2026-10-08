#!/usr/bin/env bash
# 既にある Issue に、依存する（先に終わらせる）Issue を足す。GitHub の依存関係（blocked by）に登録し、本文の「依存」にも書く
# （issue-create.sh の --blocked-by と同じく、両方に同じ番号を書く）。何度実行しても同じ結果になる（既にある依存は足さない）。
#
# 使い方: issue-depend.sh --issue N --blocked-by M [--blocked-by M2 ...] [--dry-run]
#   --issue N        依存を足す Issue の番号（#N でもよい）
#   --blocked-by M   依存する同じリポジトリの Issue の番号（#M でもよい）。複数回指定できる
#   --dry-run        変更せず、行う予定の操作だけを出力する
#
# 行うこと:
#   1. Issue N と、依存する Issue M があるかを確かめる（PR の番号・無い番号か、N が閉じていれば、何も変えずに止まる）。
#      M が閉じていれば、待つものが無いので、警告して M だけを飛ばす（skipped_closed に出す）
#   2. M が GitHub の依存関係に無ければ登録する（依存が循環するなど、GitHub が断ったら、その理由を出して止まる）
#   3. 本文の「## 依存」の節に「#M」が無ければ、最初の節に「- #M」を足す。節の中身が task-create の書く「- なし」の1行だけなら、
#      その行を置き換える（ほかの書き方の行は消さない）。節が無ければ、本文の最後に足す
#
# 出力の all_closed は、依存する Issue が全部閉じていて、何も足すものが無かったとき true（task-start が、待たずに着手するかを聞き直す）
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(CDPATH='' cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require gh jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

# オプションの値を取り出す。無ければ使い方の誤り（64）で終了する
need_value() {
  if [ $# -lt 2 ] || [ -z "$2" ]; then
    dw_die "$1 に値がありません" 64
  fi
}

issue="" dry_run=false
# 依存する Issue の番号（空白区切り。重複は除く）
blocked_by=""
while [ $# -gt 0 ]; do
  case "$1" in
    --issue)
      need_value "$@"
      issue="$(dw_issue_number "$1" "$2")"
      shift 2
      ;;
    --blocked-by)
      need_value "$@"
      n="$(dw_issue_number "$1" "$2")"
      case " $blocked_by " in
        *" $n "*) ;;
        *) blocked_by="${blocked_by:+$blocked_by }$n" ;;
      esac
      shift 2
      ;;
    --dry-run) dry_run=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done
[ -n "$issue" ] || dw_die "--issue は必須です" 64
[ -n "$blocked_by" ] || dw_die "--blocked-by は必須です" 64
case " $blocked_by " in
  *" $issue "*) dw_die "Issue #${issue} は自分自身に依存できません" 64 ;;
esac

repo_nwo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
issue_dir="repos/$repo_nwo/issues"

actions='[]'
note() { actions="$(jq -c --arg a "$1" '. + [$a]' <<<"$actions")"; }

# --- 1. Issue と依存する Issue を確かめる ---------------------------------------------
# PR の番号は無い Issue として扱う（dw_issue_json）
target="$(dw_issue_json "$repo_nwo" "$issue")"
[ -n "$target" ] || dw_die "Issue #${issue} がありません（${repo_nwo}）" 2
[ "$(jq -r .state <<<"$target")" = open ] || dw_die "Issue #${issue} は閉じています" 2
# 閉じた Issue への依存は、待つものが無いので足さない（着手中の Issue の PR が、確かめた後でマージされることもある。
# ほかの依存は足す）。無い Issue は書き間違いなので、何も変えずに止まる。「番号:id」を空白区切りで持つ
blocking="" open_numbers="" skipped_closed=""
for n in $blocked_by; do
  ref="$(dw_issue_ref "$repo_nwo" "$n")"
  [ -n "$ref" ] || dw_die "依存する Issue #${n} がありません（${repo_nwo}）" 2
  if [ "${ref#* }" != open ]; then
    dw_warn "依存する Issue #${n} は閉じているので、依存に足しません"
    skipped_closed="${skipped_closed:+$skipped_closed }$n"
    continue
  fi
  blocking="${blocking:+$blocking }$n:${ref%% *}"
  open_numbers="${open_numbers:+$open_numbers }$n"
done

# --- 2. GitHub の依存関係に登録する -------------------------------------------------
# 依存する Issue が全部閉じていれば、足すものが無いので読まない
registered='[]'
if [ -n "$blocking" ]; then
  registered="$(gh api --paginate "$issue_dir/$issue/dependencies/blocked_by?per_page=100" | jq -sc '[add // [] | .[].id]')" \
    || dw_die "Issue #${issue} の依存関係を読めませんでした"
fi
added_dependency=""
for pair in $blocking; do
  n="${pair%%:*}" id="${pair#*:}"
  jq -e --argjson id "$id" 'index($id) == null' >/dev/null <<<"$registered" || continue
  note "Issue #${issue} の依存関係（blocked by）に #${n} を登録する"
  $dry_run || dw_add_blocked_by "$repo_nwo" "$issue" "$id" \
    || dw_die "Issue #${issue} の依存関係に #${n} を登録できませんでした"
  added_dependency="${added_dependency:+$added_dependency }$n"
done

# --- 3. 本文の「依存」に書く ----------------------------------------------------------
# 節は next-tasks.sh と同じ読み方（DW_JQ_ISSUE_SECTIONS）で探す。どの「依存」の節にも無い #M だけを、最初の節の最後の行
# （空行を除く）の後に足す。最初の節の中身が、task-create の書く「- なし」と同じ1行だけなら、その行を置き換える。
# 「なし」のほかの書き方（記号・理由・コメントの付いたもの）は見分けない。使う人が自由に書いた文を推し量って書き換えると、
# 書き方ごとに例外が増え、消してはいけない行を消すため。その行は残し、後ろに足す（next-tasks.sh は #N だけを読むので、判定は変わらない）。
# 足す行の改行は、本文に合わせる（DW_JQ_LINES）
# jq の変数（$l など）を bash に展開させないため、シングルクォートで書く
# shellcheck disable=SC2016
edit="$DW_JQ_ISSUE_SECTIONS$DW_JQ_LINES"'
  (.body // "") as $body
  | body_lines as $l
  | section_ranges_of($l; "依存") as $rs
  | ([$rs[] | $l[.head + 1:.end][] | scan("#([0-9]+)") | .[0] | tonumber] | unique) as $have
  | [$ns[] | select(. as $n | $have | index($n) | not)] as $new
  | ($new | map("- #\(.)")) as $items
  | {added: $new,
     body: (if ($new | length) == 0 then $body
       elif ($rs | length) == 0 then
         ($l | crlf) as $cr
         | (($body | sub("[\r\n]+$"; "")) as $b | (if $b == "" then "" else $b + $cr + "\n" + $cr + "\n" end)
           + (["## 依存"] + $items | map(. + $cr + "\n") | join("")))
       else
         ($rs[0]) as $r
         | [range($r.head + 1; $r.end) | select($l[.] | gsub("\r"; "") | test("\\S"))] as $filled
         | if ($filled | length) == 1 and ($l[$filled[0]] | gsub("\r"; "") | test("^[ \t]*- なし[ \t]*$")) then
             # 「- なし」の行の後に足してから、その行を消す（改行の無い最後の行でも、改行が本文に合う）
             $l | insert_after($filled[0]; $items) | del(.[$filled[0]]) | join("\n")
           else $l | insert_after($filled | last // $r.head; $items) | join("\n") end
       end)}'
edited="$(jq -c --argjson ns "$(jq -nc --arg b "$open_numbers" '$b | split(" ") | map(select(. != "") | tonumber)')" "$edit" <<<"$target")"
added_body="$(jq -r '.added | join(" ")' <<<"$edited")"
if [ -n "$added_body" ]; then
  note "Issue #${issue} の本文の「依存」に $(jq -r '.added | map("#\(.)") | join("、")' <<<"$edited") を書く"
  if ! $dry_run; then
    jq -j .body <<<"$edited" | gh issue edit "$issue" --body-file - >/dev/null \
      || dw_die "Issue #${issue} の本文の「依存」を書き換えられませんでした（もう一度実行すれば書きます）"
  fi
fi

jq -n --argjson issue "$issue" --arg url "$(jq -r .html_url <<<"$target")" --arg blocked "$blocked_by" \
  --arg dep "$added_dependency" --arg body "$added_body" --arg closed "$skipped_closed" --argjson dry "$dry_run" \
  --argjson actions "$actions" '
  def nums: split(" ") | map(select(. != "") | tonumber);
  ($blocked | nums) as $b | ($closed | nums) as $c
  | {issue: $issue, url: $url, dry_run: $dry, blocked_by: $b,
   added: {dependency: ($dep | nums), body: ($body | nums)}, skipped_closed: $c,
   all_closed: (($b | length) > 0 and ($b - $c | length) == 0), actions: $actions}'
