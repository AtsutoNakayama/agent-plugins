# shellcheck shell=bash
# branch-name・status-set・task-start・cleanup・pr-create・issue-cancel のテストで使う偽の gh。load fake_gh で読み込み、setup_fake_gh を呼ぶ。
#
# - gh repo view                    me/demo を返す
# - gh issue view N --json ...      $FIX/issue-N.json を返す（-q があれば適用する）。引数を「issue-view N ...」として $CALLS に記録する
# - gh issue edit N ...             引数を「edit N ...」として $CALLS に記録する
# - gh issue comment N --body-file -  「issue-comment N」を $CALLS に記録し、標準入力を $TMP/issue-comment-body に写す
# - gh issue close N ...            引数を「issue-close N ...」として $CALLS に記録する
# - gh pr list ...                  $FIX/pr-list.json（無ければ []）を返し、引数を「pr-list ...」として $CALLS に記録する
# - gh pr create ...                引数を「pr-create ...」として $CALLS に記録し、--body-file の中身を $TMP/pr-body に写して、
#                                   https://github.com/me/demo/pull/42 を返す
# - gh pr comment N --body-file -   「pr-comment N」を $CALLS に記録し、標準入力を $TMP/pr-comment-body に写す
# - gh pr close N                   「pr-close N」を $CALLS に記録する
# - gh --version                    gh version $FAKE_GH_VERSION（既定: 2.96.0）を返す
# - gh api user                     login: me を返す
# - gh api repos/...                「api-get <パス>」を $CALLS に記録する。$FIX/remote-ref があれば {} を、無ければ HTTP 404 で失敗する
# - gh api -X DELETE <パス>          「api-delete <パス>」を $CALLS に記録する
# - gh api graphql                  操作名ごとに $FIX/<操作名>.json を返し、「<操作名> <変数>」を $CALLS に記録する
# - gh project ・Project の REST     fake_gh_project.bash が受け持つ（ProjectView・ProjectFields・AddItem・SetField など）
# FAKE_FAIL に指定した操作名（issue-view・edit・issue-comment・issue-close・pr-list・pr-create・pr-comment・pr-close・api-get・api-delete を含む）は、FAKE_FAIL_MSG（既定: gh: failed）を出して失敗する。

setup_fake_gh() {
  FIX="$TMP/fix"
  CALLS="$TMP/calls"
  export FIX CALLS
  mkdir -p "$TMP/bin" "$FIX"
  : >"$CALLS"
  cat >"$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
# shellcheck source=/dev/null
. "$FAKE_GH_PROJECT"
fake_gh_project "$@"
q=.
for a in "$@"; do
  if [ "${prev:-}" = -q ]; then q="$a"; fi
  prev="$a"
done
fail() { if [ "${FAKE_FAIL:-}" = "$1" ]; then echo "${FAKE_FAIL_MSG:-gh: failed}" >&2; exit 1; fi; }
case "$1 $2" in
  "repo view") echo '{"nameWithOwner": "me/demo", "url": "https://github.com/me/demo"}' | jq -r "$q" ;;
  "--version "*) echo "gh version ${FAKE_GH_VERSION:-2.96.0} (2026-07-02)" ;;
  "issue view")
    echo "issue-view $3 ${*:4}" >>"$CALLS"
    fail issue-view
    [ -f "$FIX/issue-$3.json" ] || { echo "GraphQL: Could not resolve to an issue (NOT_FOUND)" >&2; exit 1; }
    jq -r "$q" "$FIX/issue-$3.json"
    ;;
  "issue edit")
    shift 2
    echo "edit $*" >>"$CALLS"
    fail edit
    ;;
  "issue comment")
    echo "issue-comment $3" >>"$CALLS"
    fail issue-comment
    cat >"$(dirname "$FIX")/issue-comment-body"
    ;;
  "issue close")
    shift 2
    echo "issue-close $*" >>"$CALLS"
    fail issue-close
    ;;
  "pr comment")
    echo "pr-comment $3" >>"$CALLS"
    fail pr-comment
    cat >"$(dirname "$FIX")/pr-comment-body"
    ;;
  "pr close")
    echo "pr-close $3" >>"$CALLS"
    fail pr-close
    ;;
  "api -X")
    echo "api-delete $4" >>"$CALLS"
    fail api-delete
    ;;
  "api repos/"*)
    echo "api-get $2" >>"$CALLS"
    fail api-get
    [ -f "$FIX/remote-ref" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    echo '{}'
    ;;
  "pr list")
    shift 2
    echo "pr-list $*" >>"$CALLS"
    fail pr-list
    if [ -f "$FIX/pr-list.json" ]; then jq -r "$q" "$FIX/pr-list.json"; else echo '[]' | jq -r "$q"; fi
    ;;
  "pr create")
    shift 2
    echo "pr-create $*" >>"$CALLS"
    fail pr-create
    while [ $# -gt 0 ]; do
      if [ "$1" = --body-file ]; then cp "$2" "$(dirname "$FIX")/pr-body"; fi
      shift
    done
    echo https://github.com/me/demo/pull/42
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

  echo '{"project": {"owner": "me", "number": 4}}' >"$REPO/.claude/dev-workflow/config.json"
  fake_issue 17 '["feat"]'
  echo '{"id": "P4", "number": 4, "url": "u", "owner": {"login": "me", "type": "User"}}' >"$FIX/ProjectView.json"
  # REST の項目の一覧。id は数値、node_id が gh project で使う id
  jq -n '[{id: 1, node_id: "F1", name: "Status", data_type: "single_select", options: [
    {id: "O1", name: {raw: "Todo"}}, {id: "O2", name: {raw: "In Progress"}}, {id: "O3", name: {raw: "Done"}}]}]' \
    >"$FIX/ProjectFields.json"
  issue_item Todo
  echo '{"id": "IT9"}' >"$FIX/AddItem.json"
}

# 使い方: fake_issue <番号> <ラベルの配列> [状態（既定 OPEN）] [割り当てられた login の配列]
fake_issue() {
  jq -n --argjson n "$1" --argjson l "$2" --arg s "${3:-OPEN}" --argjson a "${4:-[]}" \
    '{number: $n, url: "https://github.com/me/demo/issues/\($n)", title: "作業 \($n)", state: $s, labels: ($l | map({name: .})), assignees: ($a | map({login: .}))}' \
    >"$FIX/issue-$1.json"
}

# Project P4 での Issue の項目と今の列。使い方: issue_item <列名 | none（列が空） | absent（Project に無い）>
issue_item() {
  jq -n --arg s "$1" '{data: {repository: {issue: {url: "https://github.com/me/demo/issues/17", projectItems: {nodes: (
    if $s == "absent" then [] else [{id: "IT1", project: {id: "P4"},
      fieldValueByName: (if $s == "none" then null else {name: $s} end)}] end)}}}}}' >"$FIX/IssueItem.json"
}

called() { grep -c "^$1 " "$CALLS" || true; }
# 使い方: args <操作名> [何回目か] → 記録した変数
args() { grep "^$1 " "$CALLS" | sed -n "${2:-1}p" | cut -d' ' -f2-; }

# 標準エラーの警告の後ろに出る JSON だけを取り出す
# macOS の BSD sed は日本語を含む入力で失敗することがあるので、バイト列として扱わせる
json_of() { printf '%s\n' "$1" | LC_ALL=C sed -n '/^{/,$p'; }
