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
#   1. Issue N と、依存する Issue M があるかを確かめる（PR の番号や無い番号なら、何も変えずに止まる）
#   2. M が GitHub の依存関係に無ければ登録する
#   3. 本文の「## 依存」の見出しの下に「- #M」が無ければ足す。「- なし」の行は消す。見出しが無ければ、本文の最後に足す
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
# REST の issues は PR も返すので、PR の番号は無い Issue として扱う
target="$(dw_gh_find gh api "$issue_dir/$issue")"
jq -e '. != null and (.pull_request | not)' >/dev/null <<<"$target" || dw_die "Issue #${issue} がありません（${repo_nwo}）" 2
# 依存関係の登録（REST）には node id ではなく数値の id を使う。「番号:id」を空白区切りで持つ
blocking=""
for n in $blocked_by; do
  id="$(dw_gh_find gh api "$issue_dir/$n" | jq -r 'if . == null or .pull_request then empty else .id end')"
  [ -n "$id" ] || dw_die "依存する Issue #${n} がありません（${repo_nwo}）" 2
  blocking="${blocking:+$blocking }$n:$id"
done

# --- 2. GitHub の依存関係に登録する -------------------------------------------------
registered="$(gh api --paginate "$issue_dir/$issue/dependencies/blocked_by?per_page=100" | jq -sc '[add // [] | .[].id]')" \
  || dw_die "Issue #${issue} の依存関係を読めませんでした"
added_dependency=""
for pair in $blocking; do
  n="${pair%%:*}" id="${pair#*:}"
  jq -e --argjson id "$id" 'index($id) == null' >/dev/null <<<"$registered" || continue
  note "Issue #${issue} の依存関係（blocked by）に #${n} を登録する"
  $dry_run || gh api -X POST "$issue_dir/$issue/dependencies/blocked_by" -F issue_id="$id" >/dev/null \
    || dw_die "Issue #${issue} の依存関係に #${n} を登録できませんでした"
  added_dependency="${added_dependency:+$added_dependency }$n"
done

# --- 3. 本文の「依存」に書く ----------------------------------------------------------
# 見出しの読み方は next-tasks.sh と同じ（## 依存。前後の空白と行末の \r は無視する）。見出しの下に既にある #M は足さない。
# 「なし」の行（`なし` も）は、依存ができたので消す。行末の \r（GitHub の画面で書いた本文）は、見出しの行に合わせる
# jq の変数（$l など）を bash に展開させないため、シングルクォートで書く
# shellcheck disable=SC2016
edit='
  (.body // "") as $body
  | ($body | split("\n")) as $l
  | ([range(0; $l | length) | select($l[.] | sub("\r$"; "") | test("^##[ \t]*依存[ \t]*$"))] | first) as $h
  | if $h == null then
      ($ns | map("- #\(.)")) as $add
      | {added: $ns,
         body: (($body | sub("[\r\n]+$"; "")) as $b | if $b == "" then "" else $b + "\n\n" end)
           + "## 依存\n" + ($add | join("\n")) + "\n"}
    else
      ([range($h + 1; $l | length) | select($l[.] | test("^## "))] | first // ($l | length)) as $end
      | ([$l[$h + 1:$end][] | scan("#([0-9]+)") | .[0] | tonumber]) as $have
      | [$ns[] | select(. as $n | $have | index($n) | not)] as $new
      | if ($new | length) == 0 then {added: [], body: $body}
        else
          (if $l[$h] | endswith("\r") then "\r" else "" end) as $cr
          | [$l[$h + 1:$end][] | select(gsub("`"; "") | test("^[ \t]*[-*][ \t]+なし") | not)] as $sec
          | ([range(0; $sec | length) | select($sec[.] | sub("\r$"; "") | test("\\S"))] | last) as $last
          | (if $last == null then 0 else $last + 1 end) as $at
          | {added: $new,
             body: ($l[:$h + 1] + $sec[:$at] + ($new | map("- #\(.)" + $cr)) + $sec[$at:] + $l[$end:] | join("\n"))}
        end
    end'
edited="$(jq -c --argjson ns "$(jq -nc --arg b "$blocked_by" '$b | split(" ") | map(tonumber)')" "$edit" <<<"$target")"
added_body="$(jq -r '.added | join(" ")' <<<"$edited")"
if [ -n "$added_body" ]; then
  note "Issue #${issue} の本文の「依存」に $(jq -r '.added | map("#\(.)") | join("、")' <<<"$edited") を書く"
  if ! $dry_run; then
    jq -j .body <<<"$edited" | gh issue edit "$issue" --body-file - >/dev/null \
      || dw_die "Issue #${issue} の本文の「依存」を書き換えられませんでした（もう一度実行すれば書きます）"
  fi
fi

jq -n --argjson issue "$issue" --arg url "$(jq -r .html_url <<<"$target")" --arg blocked "$blocked_by" \
  --arg dep "$added_dependency" --arg body "$added_body" --argjson dry "$dry_run" --argjson actions "$actions" '
  def nums: split(" ") | map(select(. != "") | tonumber);
  {issue: $issue, url: $url, dry_run: $dry, blocked_by: ($blocked | nums),
   added: {dependency: ($dep | nums), body: ($body | nums)}, actions: $actions}'
