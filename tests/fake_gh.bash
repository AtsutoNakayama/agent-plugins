# shellcheck shell=bash
# branch-name・status-set・task-start のテストで使う偽の gh。load fake_gh で読み込み、setup_fake_gh を呼ぶ。
#
# - gh repo view                    me/demo を返す
# - gh issue view N --json ...      $FIX/issue-N.json を返す（-q があれば適用する）
# - gh issue edit N ...             引数を「edit N ...」として $CALLS に記録する
# - gh api user                     login: me を返す
# - gh api graphql                  操作名ごとに $FIX/<操作名>.json を返し、「<操作名> <変数>」を $CALLS に記録する
# FAKE_FAIL に指定した操作名（edit を含む）は、FAKE_FAIL_MSG（既定: gh: failed）を出して失敗する。

setup_fake_gh() {
  FIX="$TMP/fix"
  CALLS="$TMP/calls"
  export FIX CALLS
  mkdir -p "$TMP/bin" "$FIX"
  : >"$CALLS"
  cat >"$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
q=.
for a in "$@"; do
  if [ "${prev:-}" = -q ]; then q="$a"; fi
  prev="$a"
done
fail() { if [ "${FAKE_FAIL:-}" = "$1" ]; then echo "${FAKE_FAIL_MSG:-gh: failed}" >&2; exit 1; fi; }
case "$1 $2" in
  "repo view") echo '{"nameWithOwner": "me/demo"}' | jq -r "$q" ;;
  "issue view")
    [ -f "$FIX/issue-$3.json" ] || { echo "GraphQL: Could not resolve to an issue (NOT_FOUND)" >&2; exit 1; }
    jq -r "$q" "$FIX/issue-$3.json"
    ;;
  "issue edit")
    shift 2
    echo "edit $*" >>"$CALLS"
    fail edit
    ;;
  "api user") echo '{"login": "me"}' | jq -r "$q" ;;
  "api graphql")
    body="$(cat)"
    op="$(jq -r .query <<<"$body" | grep -oE '(query|mutation) [A-Za-z]+' | head -n 1 | cut -d' ' -f2)"
    echo "$op $(jq -c .variables <<<"$body")" >>"$CALLS"
    fail "$op"
    if [ -f "$FIX/$op.json" ]; then cat "$FIX/$op.json"; else echo '{"data": {}}'; fi
    ;;
esac
SH
  chmod +x "$TMP/bin/gh"
  export PATH="$TMP/bin:$PATH"

  echo '{"project": {"owner": "me", "number": 4}}' >"$REPO/.claude/workflow.json"
  fake_issue 17 '["feat"]'
  jq -n '{data: {repositoryOwner: {projectV2: {id: "P4", number: 4, url: "u", fields: {nodes: [
    {id: "F1", name: "Status", dataType: "SINGLE_SELECT", options: [
      {id: "O1", name: "Todo"}, {id: "O2", name: "In Progress"}, {id: "O3", name: "Done"}]}]}}}}}' \
    >"$FIX/ProjectFields.json"
  issue_item Todo
  echo '{"data": {"addProjectV2ItemById": {"item": {"id": "IT9"}}}}' >"$FIX/AddItem.json"
  echo '{"data": {"updateProjectV2ItemFieldValue": {"projectV2Item": {"id": "IT1"}}}}' >"$FIX/SetField.json"
}

# 使い方: fake_issue <番号> <ラベルの配列> [状態（既定 OPEN）] [割り当てられた login の配列]
fake_issue() {
  jq -n --argjson n "$1" --argjson l "$2" --arg s "${3:-OPEN}" --argjson a "${4:-[]}" \
    '{number: $n, title: "作業 \($n)", state: $s, labels: ($l | map({name: .})), assignees: ($a | map({login: .}))}' \
    >"$FIX/issue-$1.json"
}

# Project P4 での Issue の項目と今の列。使い方: issue_item <列名 | none（列が空） | absent（Project に無い）>
issue_item() {
  jq -n --arg s "$1" '{data: {repository: {issue: {id: "I17", projectItems: {nodes: (
    if $s == "absent" then [] else [{id: "IT1", project: {id: "P4"},
      fieldValueByName: (if $s == "none" then null else {name: $s} end)}] end)}}}}}' >"$FIX/IssueItem.json"
}

called() { grep -c "^$1 " "$CALLS" || true; }
# 使い方: args <操作名> [何回目か] → 記録した変数
args() { grep "^$1 " "$CALLS" | sed -n "${2:-1}p" | cut -d' ' -f2-; }

# 標準エラーの警告の後ろに出る JSON だけを取り出す
# macOS の BSD sed は日本語を含む入力で失敗することがあるので、バイト列として扱わせる
json_of() { printf '%s\n' "$1" | LC_ALL=C sed -n '/^{/,$p'; }
