#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper

# 偽の gh。
# - gh repo view ... -q .nameWithOwner  me/demo を返す
# - gh pr view [番号] --json ...   $FIX/pr-view.json を返す。「PrView <引数>」を $CALLS に記録する。無ければ PR が無いとして失敗する
# - gh api graphql                「PrThreads <変数>」を $CALLS に記録し、$FIX/PrThreads.<n>.json（n 回目。無ければ PrThreads.json）を返す
# FAKE_FAIL に指定した操作名（PrView・PrThreads）は、FAKE_FAIL_MSG（既定: gh: failed）を出して失敗する。
setup_fake_gh() {
  FIX="$TMP/fix"
  CALLS="$TMP/calls"
  export FIX CALLS
  mkdir -p "$TMP/bin" "$FIX"
  : >"$CALLS"
  cat >"$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
fail() { if [ "${FAKE_FAIL:-}" = "$1" ]; then echo "${FAKE_FAIL_MSG:-gh: failed}" >&2; exit 1; fi; }
case "$1 $2" in
  "repo view") echo me/demo ;;
  "pr view")
    echo "PrView ${*:3}" >>"$CALLS"
    fail PrView
    [ -f "$FIX/pr-view.json" ] || { echo 'no pull requests found for branch "feat/5-x"' >&2; exit 1; }
    cat "$FIX/pr-view.json"
    ;;
  "api graphql")
    body="$(cat)"
    echo "PrThreads $(jq -c .variables <<<"$body")" >>"$CALLS"
    fail PrThreads
    n="$(grep -c '^PrThreads ' "$CALLS")"
    if [ -f "$FIX/PrThreads.$n.json" ]; then cat "$FIX/PrThreads.$n.json"; else cat "$FIX/PrThreads.json"; fi
    ;;
  *) echo "gh: 想定外の呼び出し: $*" >&2; exit 1 ;;
esac
SH
  chmod +x "$TMP/bin/gh"
  export PATH="$TMP/bin:$PATH"
  : >"$FIX/threads"
  pr_view '{}'
  write_threads
}

# PR の JSON を作る。使い方: pr_view <既定の値に上書きするオブジェクト（jq の式）>
pr_view() {
  jq -n "$1 as \$o | "'{number: 5, url: "https://github.com/me/demo/pull/5", title: "feat: x", state: "OPEN", isDraft: false,
    author: {login: "me"}, headRefName: "feat/5-x", headRefOid: "abc", baseRefName: "main", mergeable: "MERGEABLE", mergeStateStatus: "CLEAN",
    reviewDecision: "", reviews: [], comments: [], statusCheckRollup: []} + $o' >"$FIX/pr-view.json"
}

# スレッドを1つ足す（write_threads で GraphQL の応答にする）。使い方: thread <resolved か> <コメントの JSON の配列>
# コメントは [[投稿者, 本文], ...]
thread() {
  jq -nc --argjson r "$1" --argjson c "$2" '{isResolved: $r, isOutdated: false, path: "a.sh", line: 3,
    comments: {nodes: [$c | to_entries[] | {databaseId: (100 + .key), author: {login: .value[0]}, body: .value[1],
      url: "https://github.com/me/demo/pull/5#discussion_r\(100 + .key)", createdAt: "2026-10-01T00:00:0\(.key)Z"}]}}' >>"$FIX/threads"
}

# 足したスレッドを、1ページ分の応答にする。使い方: write_threads [ファイル名（既定 PrThreads.json）] [次のページがあるか] [次のカーソル（既定 C1。null も指定できる）]
write_threads() {
  jq -sc --argjson next "${2:-false}" --argjson cursor "\"${3:-C1}\"" '{data: {repository: {pullRequest: {reviewThreads: {
    pageInfo: {hasNextPage: $next, endCursor: (if $cursor == "null" then null else $cursor end)}, nodes: .}}}}}' \
    "$FIX/threads" >"$FIX/${1:-PrThreads.json}"
  : >"$FIX/threads"
}

called() { grep -c "^$1 " "$CALLS" || true; }
args() { grep "^$1 " "$CALLS" | sed -n "${2:-1}p" | cut -d' ' -f2-; }
out_of() { jq -c "$1" <<<"$output"; }

@test "コメントの無い PR は、状態だけを出し、feedback は空になる" {
  setup_fake_gh
  run_script pr-feedback.sh
  assert_success
  assert_equal "$(out_of '.pr | [.number, .state, .author, .head, .head_sha, .merge_state, .review_decision]')" '[5,"OPEN","me","feat/5-x","abc","CLEAN",null]'
  assert_equal "$(out_of '[.feedback, .own_comments, .counts, .checks.state]')" '[[],[],{"threads":0,"reviews":0,"comments":0},"none"]'
  # 番号を指定しなければ、今のブランチの PR を読む
  assert_equal "$(args PrView)" "--json number,url,title,state,isDraft,author,headRefName,headRefOid,baseRefName,mergeable,mergeStateStatus,reviewDecision,reviews,comments,statusCheckRollup"
  # スレッドは今のリポジトリで読む
  assert_equal "$(args PrThreads)" '{"owner":"me","name":"demo","number":5}'
}

@test "--pr は 5 でも #5 でも、その番号の PR を読む" {
  setup_fake_gh
  run_script pr-feedback.sh --pr '#5'
  assert_success
  run_script pr-feedback.sh --pr 5
  assert_success
  assert_equal "$(args PrView 1 | cut -d' ' -f1)" 5
  assert_equal "$(args PrView 2 | cut -d' ' -f1)" 5
}

@test "--pr の先頭の 0 はそろえる（005 も 5 の PR を読む。番号の受け取り方は Issue と同じ）" {
  setup_fake_gh
  run_script pr-feedback.sh --pr 005
  assert_success
  assert_equal "$(args PrView 1 | cut -d' ' -f1)" 5
}

@test "--pr が PR の番号でなければ（数字でない・# だけ・## で始まる・0）、使い方の誤りで止まる" {
  setup_fake_gh
  for v in abc '#' 5x '##5' 0 000; do
    run_script pr-feedback.sh --pr "$v"
    assert_failure 64
    assert_output --partial "--pr には PR の番号を指定してください: $v"
  done
  run_script pr-feedback.sh --pr
  assert_failure 64
  assert_equal "$(called PrView)" 0
}

@test "今のブランチに PR が無ければ、番号の指定を促して止まる" {
  setup_fake_gh
  rm "$FIX/pr-view.json"
  run_script pr-feedback.sh
  assert_failure 1
  assert_output --partial "今のブランチの PR を読めません（--pr で番号を指定してください）"
}

@test "指摘を投稿者ごとにまとめ、PR の作者のものと本文の無いコメントのレビューは数えない" {
  setup_fake_gh
  pr_view '{
    reviews: [
      {id: "R1", author: {login: "alice"}, state: "COMMENTED", body: "全体に1つ質問です", submittedAt: "t1", commit: {oid: "abc"}},
      {id: "R2", author: {login: "alice"}, state: "COMMENTED", body: "", submittedAt: "t2", commit: {oid: "abc"}},
      {id: "R3", author: {login: "bob"}, state: "APPROVED", body: "", submittedAt: "t3", commit: {oid: "abc"}},
      {id: "R4", author: {login: "me"}, state: "COMMENTED", body: "自分のメモ", submittedAt: "t4", commit: {oid: "abc"}}],
    comments: [
      {id: "C1", author: {login: "bob"}, body: "なぜこの名前に？", createdAt: "t5", url: "u5"},
      {id: "C2", author: {login: "me"}, body: "返信です", createdAt: "t6", url: "u6"}]}'
  run_script pr-feedback.sh
  assert_success
  assert_equal "$(out_of '[.feedback[].author]')" '["alice","bob"]'
  assert_equal "$(out_of '[.feedback[] | {author, r: [.reviews[].id], c: [.comments[].id]}]')" \
    '[{"author":"alice","r":["R1"],"c":[]},{"author":"bob","r":["R3"],"c":["C1"]}]'
  assert_equal "$(out_of .counts)" '{"threads":0,"reviews":2,"comments":1}'
  # PR の作者のコメントは、返信済みかの判断に使えるよう own_comments に出す
  assert_equal "$(out_of '[.own_comments[] | [.id, .body]]')" '[["C2","返信です"]]'
}

@test "resolved でないスレッドだけを出し、PR の作者以外の投稿者のものにする" {
  setup_fake_gh
  thread false '[["alice", "ここは null になりませんか"], ["me", "直しました"]]'
  thread true '[["alice", "解決済みの指摘"]]'
  thread false '[["me", "自分で立てたスレッド"], ["bob", "それなら別案があります"]]'
  thread false '[["me", "自分だけのメモ"]]'
  write_threads
  run_script pr-feedback.sh
  assert_success
  assert_equal "$(out_of '[.feedback[] | {author, t: [.threads[] | [.id, .replied, (.comments | length)]]}]')" \
    '[{"author":"alice","t":[[100,true,2]]},{"author":"bob","t":[[100,false,2]]}]'
  assert_equal "$(out_of '.feedback[0].threads[0] | [.path, .line, .outdated, .url, .comments[0].author, .comments[0].body]')" \
    '["a.sh",3,false,"https://github.com/me/demo/pull/5#discussion_r100","alice","ここは null になりませんか"]'
  assert_equal "$(out_of .counts.threads)" 2
}

@test "担当の skill が無い書き手（人）がいるスレッドは、順番によらず、その人の分にする" {
  setup_fake_gh
  echo '{"pr_check": {"handlers": {"coderabbitai[bot]": "coderabbit-respond"}}}' >"$REPO/.claude/dev-workflow/config.json"
  # bot のスレッドに人が質問を書いたら、担当の skill（人のコメントを扱わない）ではなく、その人の分として汎用の手順で扱う
  thread false '[["coderabbitai", "指摘"], ["alice", "この指摘は本当ですか"]]'
  thread false '[["coderabbitai", "指摘"], ["me", "直しました"], ["alice", "直し方に質問です"]]'
  # 人の後に bot が返しても、人の分のまま（bot の分に戻すと、人の質問を誰も扱わない）
  thread false '[["coderabbitai", "指摘"], ["alice", "どう直す？"], ["coderabbitai", "こう直します"]]'
  # 人が2人いれば、その中で最後に書いた人の分
  thread false '[["alice", "質問"], ["bob", "補足"], ["coderabbitai", "要約"]]'
  # PR の作者と bot だけのスレッドは、bot の分（担当の skill に任せる）
  thread false '[["coderabbitai", "指摘"], ["me", "@coderabbitai 直しました"]]'
  write_threads
  run_script pr-feedback.sh
  assert_success
  assert_equal "$(out_of '[.feedback[] | {author, handler, n: (.threads | length)}]')" \
    '[{"author":"alice","handler":null,"n":3},{"author":"bob","handler":null,"n":1},{"author":"coderabbitai","handler":"coderabbit-respond","n":1}]'
}

@test "replied は、スレッドの持ち主の最後のコメントの後に PR の作者が書いたかで決める" {
  setup_fake_gh
  echo '{"pr_check": {"handlers": {"coderabbitai[bot]": "coderabbit-respond"}}}' >"$REPO/.claude/dev-workflow/config.json"
  # alice の分。作者が alice に答えた後に bot が書いても、alice には返信済み
  thread false '[["coderabbitai", "指摘"], ["alice", "質問"], ["me", "回答"], ["coderabbitai", "確認"]]'
  # alice の分。作者の返信の後に alice が書いたので、返信していない
  thread false '[["alice", "質問"], ["me", "回答"], ["alice", "追加の質問"]]'
  # bot の分。作者が最後に書いたので、返信済み
  thread false '[["coderabbitai", "指摘"], ["me", "@coderabbitai 直しました"]]'
  write_threads
  run_script pr-feedback.sh
  assert_success
  assert_equal "$(out_of '[.feedback[] | [.author, [.threads[].replied]]]')" '[["alice",[true,false]],["coderabbitai",[true]]]'
}

@test "担当の設定が無ければ、スレッドは PR の作者以外で最後に書いた人の分にする" {
  setup_fake_gh
  thread false '[["alice", "指摘"], ["bob", "補足"], ["me", "直しました"]]'
  write_threads
  run_script pr-feedback.sh
  assert_success
  assert_equal "$(out_of '[.feedback[] | [.author, (.threads | length)]]')" '[["bob",1]]'
}

@test "担当の skill を、大文字と小文字・末尾の [bot] を区別せずに投稿者へ対応させる" {
  setup_fake_gh
  echo '{"pr_check": {"handlers": {"CodeRabbitAI[bot]": "coderabbit-respond"}}}' >"$REPO/.claude/dev-workflow/config.json"
  pr_view '{comments: [
    {id: "C1", author: {login: "coderabbitai"}, body: "要約", createdAt: "t1", url: "u1"},
    {id: "C2", author: {login: "alice"}, body: "質問", createdAt: "t2", url: "u2"}]}'
  run_script pr-feedback.sh
  assert_success
  assert_equal "$(out_of '[.feedback[] | [.author, .handler]]')" '[["alice",null],["coderabbitai","coderabbit-respond"]]'
  assert_equal "$(out_of .handlers)" '{"CodeRabbitAI[bot]":"coderabbit-respond"}'
}

@test "設定が無ければ、どの投稿者にも担当の skill は無い" {
  setup_fake_gh
  pr_view '{comments: [{id: "C1", author: {login: "coderabbitai"}, body: "要約", createdAt: "t1", url: "u1"}]}'
  run_script pr-feedback.sh
  assert_success
  assert_equal "$(out_of '[.handlers, .feedback[0].handler]')" '[{},null]'
}

@test "旧キー pr_respond が設定に残っていれば、使われないことを警告し、担当の skill には任せない" {
  setup_fake_gh
  echo '{"pr_respond": {"handlers": {"coderabbitai[bot]": "coderabbit-respond"}}}' >"$REPO/.claude/dev-workflow/config.json"
  pr_view '{comments: [{id: "C1", author: {login: "coderabbitai"}, body: "要約", createdAt: "t1", url: "u1"}]}'
  run_script pr-feedback.sh
  assert_success
  assert_output --partial "設定のキー pr_respond は使われません。pr_check に改めてください"
  out="$("${TEST_BASH:-bash}" "$SCRIPTS/pr-feedback.sh" 2>/dev/null)"
  assert_equal "$(jq -c '[.handlers, .feedback[0].handler]' <<<"$out")" '[{},null]'
}

@test "担当の設定がオブジェクトでなければ止まる" {
  setup_fake_gh
  for h in '["coderabbit-respond"]' '{"alice": 1}' '{"alice": ""}'; do
    echo "{\"pr_check\": {\"handlers\": $h}}" >"$REPO/.claude/dev-workflow/config.json"
    run_script pr-feedback.sh
    assert_failure 1
    assert_output --partial "設定の pr_check.handlers は、投稿者を担当する skill の名前に対応させるオブジェクトにしてください"
  done
  assert_equal "$(called PrView)" 0
}

@test "CI のチェックを、失敗・実行中・成功にまとめる" {
  setup_fake_gh
  pr_view '{statusCheckRollup: [
    {__typename: "CheckRun", name: "lint", workflowName: "Lint", status: "COMPLETED", conclusion: "SUCCESS", detailsUrl: "d1"},
    {__typename: "CheckRun", name: "test", workflowName: "Test", status: "COMPLETED", conclusion: "FAILURE", detailsUrl: "d2"},
    {__typename: "CheckRun", name: "build", workflowName: "Build", status: "IN_PROGRESS", conclusion: "", detailsUrl: "d3"},
    {__typename: "CheckRun", name: "skip", workflowName: "Skip", status: "COMPLETED", conclusion: "SKIPPED", detailsUrl: "d4"},
    {__typename: "StatusContext", context: "ext/ci", state: "ERROR", targetUrl: "t1"},
    {__typename: "StatusContext", context: "ext/wait", state: "PENDING", targetUrl: "t2"}]}'
  run_script pr-feedback.sh
  assert_success
  assert_equal "$(out_of '.checks | [.state, .total]')" '["failure",6]'
  assert_equal "$(out_of '[.checks.failed[] | [.name, .workflow, .url]]')" '[["test","Test","d2"],["ext/ci",null,"t1"]]'
  assert_equal "$(out_of '[.checks.pending[].name]')" '["build","ext/wait"]'
}

@test "失敗が無く実行中のチェックがあれば pending、すべて済んでいれば success" {
  setup_fake_gh
  pr_view '{statusCheckRollup: [{__typename: "CheckRun", name: "lint", status: "QUEUED", conclusion: "", detailsUrl: "d"}]}'
  run_script pr-feedback.sh
  assert_success
  assert_equal "$(out_of .checks.state)" '"pending"'
  pr_view '{statusCheckRollup: [{__typename: "CheckRun", name: "lint", status: "COMPLETED", conclusion: "NEUTRAL", detailsUrl: "d"}]}'
  run_script pr-feedback.sh
  assert_success
  assert_equal "$(out_of .checks.state)" '"success"'
}

@test "スレッドが複数のページにまたがっても、全部読む" {
  setup_fake_gh
  thread false '[["alice", "1つ目"]]'
  write_threads PrThreads.1.json true
  thread false '[["bob", "2つ目"]]'
  write_threads PrThreads.2.json false
  run_script pr-feedback.sh
  assert_success
  assert_equal "$(out_of '[.feedback[].author]')" '["alice","bob"]'
  assert_equal "$(called PrThreads)" 2
  assert_equal "$(args PrThreads 2)" '{"owner":"me","name":"demo","number":5,"after":"C1"}'
}

@test "スレッドのページ送りのカーソルが進まなければ、同じページを読み続けずに止まる" {
  setup_fake_gh
  write_threads PrThreads.json true null
  run_script pr-feedback.sh
  assert_failure 1
  assert_output --partial "PR #5 のスレッドのページ送りが進みません"
  assert_equal "$(called PrThreads)" 1
  write_threads PrThreads.1.json true C1
  write_threads PrThreads.2.json true C1
  : >"$CALLS"
  run_script pr-feedback.sh
  assert_failure 1
  assert_output --partial "PR #5 のスレッドのページ送りが進みません"
  assert_equal "$(called PrThreads)" 2
}

@test "スレッドを読めなければ、理由を伝えて止まる" {
  setup_fake_gh
  FAKE_FAIL=PrThreads FAKE_FAIL_MSG="HTTP 401: Bad credentials" run_script pr-feedback.sh
  assert_failure 1
  assert_output --partial "PR #5 のスレッドを読めません: HTTP 401: Bad credentials"
}

@test "何も変えない（gh の読み取りだけを呼ぶ）" {
  setup_fake_gh
  thread false '[["alice", "指摘"]]'
  write_threads
  run_script pr-feedback.sh
  assert_success
  assert_equal "$(cut -d' ' -f1 "$CALLS" | sort -u | tr '\n' ' ')" "PrThreads PrView "
}
