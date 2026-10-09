#!/usr/bin/env bash
# branch-update を無人で直すとき（SKILL.md の「無人で直すとき」）に、次にすることを、値だけから決めて JSON で出力する。
# 判断は入力の値だけで決める（git も GitHub も使わない）。組み合わせは tests/repair-next.bats で確かめる。
# SKILL.md の文章に書くと、テストできず、組み合わせの抜けが残るため（branch-plan.sh と同じ流儀）。
#
# 使い方: echo '<入力 JSON>' | repair-next.sh
#
# 入力（JSON）:
#   step          start（branch-status.sh の出力を見て、取り込みを始めるか決める。手順1）・
#                 verify（取り込んだ後、テストとチェックを通して push してよいか決める。手順3〜4）
#   status        branch-status.sh の出力（step が start のとき必須。verify のときは unpulled と dirty だけを使う）
#   rechecks      start で recheck を、すでに何回返されたか（既定 0。上限は 3 回）
#   checks        verify のとき。テストとチェックの状態。pending（まだ実行していない）・pass（通った。実行するものが
#                 無い `none` も pass）・fail（失敗した）・unconfirmed（checks-commands.sh の action が confirm か infer）
#   fix_attempts  verify のとき。同じ失敗を、すでに直した回数（既定 0）
#   max_fix_attempts  同じ失敗を直す回数の上限（既定 3）
#   push_check_ok verify のとき。repair-push-check.sh の ok（まだ実行していないなら null）
#
# 出力（JSON）: {action, reason}
#   action  merge（origin/<base_branch> を merge する）・pull（git pull --no-rebase で origin のブランチを取り込む）・
#           checks（テストとチェックを実行する）・fix（失敗を直す）・push_check（repair-push-check.sh を実行する）・
#           push（push する）・finish（取り込まずに、何も書き込まずに終える）・recheck（数秒待って branch-status.sh を実行し直す）・
#           stop（止まる。Issue にコメントして保留の列に移す）
#
# 判断の表（上から順に当てはめる）
#   step が start
#     1. plan.action が none                         → finish（reason: plan.reason）
#     2. plan.action が ask_base                     → stop（base_mismatch）
#     3. plan.action が recheck で rechecks が 3 未満 → recheck、3 以上 → stop（recheck_exhausted）
#     4. dirty が true                                → stop（dirty）
#     5. unpulled が 1 以上                           → pull（pulled の後に branch-status.sh を実行し直す）
#     6. plan.action が merge                         → merge
#     7. plan.action が push                          → checks（手元で取り込み済み。取り込みは飛ばす）
#     8. 上のどれでもない（plan.action が未知の値）  → stop（unknown_plan）
#   step が verify
#     1. unpulled が 1 以上                           → pull（pull の後は、手順3から進め直す）
#     2. checks が unconfirmed                        → stop（checks_unconfirmed）
#     3. checks が pending                            → checks
#     4. checks が fail で fix_attempts が上限未満    → fix、上限以上 → stop（same_failure）
#     5. checks が pass で dirty が true              → stop（dirty。未コミットの変更を push に含めない）
#     6. checks が pass で push_check_ok が null      → push_check
#     7. checks が pass で push_check_ok が false     → stop（forbidden_paths）
#     8. checks が pass で push_check_ok が true      → push
#   入力の型が違うとき（数値でない rechecks・fix_attempts・max_fix_attempts・unpulled、真偽値でない dirty・push_check_ok）は、
#   終了コード 64 で止まる（null と省略は、既定の値）
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(CDPATH='' cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done

input="$(cat)"
jq -e 'type == "object" and (.step == "start" or .step == "verify")' <<<"$input" >/dev/null 2>&1 \
  || dw_die "入力（JSON）の step は start か verify にしてください" 64
if jq -e '.step == "start" and ((.status.plan.action | type) != "string")' <<<"$input" >/dev/null; then
  dw_die "step が start のときは、status に branch-status.sh の出力を渡してください" 64
fi
if jq -e '.step == "verify" and ((.checks // "") | IN("pending", "pass", "fail", "unconfirmed") | not)' <<<"$input" >/dev/null; then
  dw_die "step が verify のときは、checks に pending・pass・fail・unconfirmed のどれかを渡してください" 64
fi

# 入力の型を確かめる（型が違う値を、既定の値や false として黙って進めない）
jq -e '
  def num: . == null or type == "number";
  def bool: . == null or type == "boolean";
  (.rechecks | num) and (.fix_attempts | num) and (.max_fix_attempts | num) and (.push_check_ok | bool)
  and ((.status // {}) | type == "object") and (.status.unpulled | num) and (.status.dirty | bool)' <<<"$input" >/dev/null 2>&1 \
  || dw_die "入力の型が違います（rechecks・fix_attempts・max_fix_attempts・status.unpulled は数値、push_check_ok・status.dirty は真偽値）" 64

jq -c '
  def r($a; $why): {action: $a, reason: $why};
  (.status.unpulled // 0) as $unpulled
  | if .step == "start" then
      .status.plan as $plan
      | if $plan.action == "none" then r("finish"; $plan.reason)
        elif $plan.action == "ask_base" then r("stop"; "base_mismatch")
        elif $plan.action == "recheck" then
          (if (.rechecks // 0) < 3 then r("recheck"; "merge_state_unknown") else r("stop"; "recheck_exhausted") end)
        elif .status.dirty == true then r("stop"; "dirty")
        elif $unpulled >= 1 then r("pull"; "unpulled")
        elif $plan.action == "merge" then r("merge"; $plan.reason)
        elif $plan.action == "push" then r("checks"; $plan.reason)
        else r("stop"; "unknown_plan") end
    elif $unpulled >= 1 then r("pull"; "unpulled")
    elif .checks == "unconfirmed" then r("stop"; "checks_unconfirmed")
    elif .checks == "pending" then r("checks"; "not_run")
    elif .checks == "fail" then
      (if (.fix_attempts // 0) < (.max_fix_attempts // 3) then r("fix"; "checks_failed") else r("stop"; "same_failure") end)
    elif .status.dirty == true then r("stop"; "dirty")
    elif .push_check_ok == null then r("push_check"; "not_checked")
    elif .push_check_ok == false then r("stop"; "forbidden_paths")
    else r("push"; "ready") end' <<<"$input"
