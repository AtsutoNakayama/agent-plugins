#!/usr/bin/env bats
# 既にある Issue を、外した親の代わりに親にできるかの判定（parent-candidate.sh）
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper

# 偽の gh。読むだけの呼び出しを受け持ち、呼ばれた操作を $CALLS に記録する。
# gh api repos/me/demo/issues/<番号> は $FIX/issue-<番号>.json を返し（無ければ 404）、「GetIssue <番号>」を記録する。
# gh api repos/<所有者>/<名前>/issues/<番号>/parent は $FIX/parent-<番号>.json を返し（無ければ 404）、「GetParent <番号>」を記録する。
# gh api repos/.../issues/<番号>/sub_issues?per_page=1 は $FIX/sub-issues-<番号>.json（無ければ []）の先頭の1件を返し、「GetSubIssues <引数>」を記録する。
# gh repo view は $FAKE_REPO（既定 me/demo）を返し、gh api repos/<FAKE_REPO>/issues/<番号> の <番号> を読む。
# それ以外の gh api は「Other <引数>」を記録して失敗する（書き込みをしないことを確かめる）。
# FAKE_FAIL に指定した操作名は、FAKE_FAIL_MSG（既定: gh: failed）を出して失敗する。
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
  "repo view") jq -n --arg r "${FAKE_REPO:-me/demo}" '{nameWithOwner: $r}' | jq -r "$q" ;;
  "api repos/"*/issues/*/sub_issues*)
    echo "GetSubIssues ${*:2}" >>"$CALLS"
    fail GetSubIssues
    path="${2%%\?*}"
    n="${path%/sub_issues}"
    n="${n##*/}"
    if [ -f "$FIX/sub-issues-$n.json" ]; then jq -c '.[:1]' "$FIX/sub-issues-$n.json"; else echo '[]'; fi
    ;;
  "api repos/"*/issues/*/parent)
    n="${2%/parent}"
    n="${n##*/}"
    echo "GetParent $n" >>"$CALLS"
    fail GetParent
    [ -f "$FIX/parent-$n.json" ] || { echo 'gh: No parent issue found (HTTP 404)' >&2; exit 1; }
    cat "$FIX/parent-$n.json"
    ;;
  "api repos/${FAKE_REPO:-me/demo}/issues/"*)
    n="${2##*/}"
    echo "GetIssue $n" >>"$CALLS"
    fail GetIssue
    [ -f "$FIX/issue-$n.json" ] || { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
    cat "$FIX/issue-$n.json"
    ;;
  *) echo "Other $*" >>"$CALLS"; echo 'gh: unexpected call' >&2; exit 1 ;;
esac
SH
  chmod +x "$TMP/bin/gh"
  export PATH="$TMP/bin:$PATH"
  echo '{}' >.claude/dev-workflow/config.json
  issue_json me/demo 12 >"$FIX/issue-12.json"
}

# REST の Issue の応答。使い方: issue_json <所有者/名前> <番号>
issue_json() {
  jq -n --arg r "$1" --argjson n "$2" \
    '{id: (1000 + $n), number: $n, url: "https://api.github.com/repos/\($r)/issues/\($n)", repository_url: "https://api.github.com/repos/\($r)"}'
}

# <子> の親を <親> にする（別のリポジトリなら <所有者/名前> も渡す）。使い方: set_parent <子> <親> [所有者/名前]
set_parent() { issue_json "${3:-me/demo}" "$2" >"$FIX/parent-$1.json"; }

# <親> のサブ Issue を <子>... にする。使い方: set_children <親> <子>...
set_children() {
  local p="$1"
  shift
  jq -n --args '$ARGS.positional | map(tonumber | {number: ., state: "open"})' "$@" >"$FIX/sub-issues-$p.json"
}

max_depth() { echo "{\"sub_issues\": {\"max_depth\": $1}}" >.claude/dev-workflow/config.json; }

@test "サブ Issue も親も持たず、上限を超えなければ、親にする" {
  setup_fake_gh
  run_script parent-candidate.sh --issue 12 --levels 1
  assert_success
  assert_equal "$output" "$(jq -n '{issue: 12, has_sub_issues: false, parent: null, depth: 2, max_depth: 3,
    has_parent: false, exceeds_max_depth: false, reasons: [], action: "use_as_parent"}')"
  # 読むだけで、書き込みをしない。サブ Issue は1件だけ読む（全ページは読まない）
  assert_equal "$(grep -c '^Other ' "$CALLS" || true)" 0
  assert_equal "$(grep '^GetSubIssues ' "$CALLS")" "GetSubIssues repos/me/demo/issues/12/sub_issues?per_page=1"
}

@test "3つの条件の組み合わせ：どれにも当てはまらないときだけ親にし、1つでも当てはまれば親なしにする" {
  setup_fake_gh
  max_depth 3
  for s in 0 1; do
    for p in 0 1; do
      for e in 0 1; do
        rm -f "$FIX/sub-issues-12.json" "$FIX/parent-12.json"
        [ "$s" = 0 ] || set_children 12 20
        [ "$p" = 0 ] || set_parent 12 5
        # 深さ = 候補の層（親が無ければ 1、あれば 2）+ 紐付ける層の数。上限 3 を超えるかを --levels で決める
        if [ "$e" = 0 ]; then levels=1; elif [ "$p" = 0 ]; then levels=3; else levels=2; fi
        run_script parent-candidate.sh --issue 12 --levels "$levels"
        assert_success
        expected="$(jq -nc --argjson s "$s" --argjson p "$p" --argjson e "$e" '
          [(if $s == 1 then "has_sub_issues" else empty end), (if $p == 1 then "has_parent" else empty end),
           (if $e == 1 then "exceeds_max_depth" else empty end)] as $r
          | [($s == 1), ($p == 1), ($e == 1), $r, (if $r == [] then "use_as_parent" else "no_parent" end)]')"
        assert_equal "$(jq -c '[.has_sub_issues, .has_parent, .exceeds_max_depth, .reasons, .action]' <<<"$output")" "$expected"
      done
    done
  done
}

@test "深さは issue-create.sh と同じく、候補から上へ親をたどって数え、別のリポジトリの親もたどる" {
  setup_fake_gh
  set_parent 12 5
  set_parent 5 2 other/repo
  run_script parent-candidate.sh --issue 12 --levels 1
  assert_success
  # 候補（3 層目）の子は 4 層目。上限 3 の手前の 2 個の親を数えたところで止める
  assert_equal "$(jq -c '[.depth, .max_depth, .exceeds_max_depth, .parent, .action]' <<<"$output")" \
    '[4,3,true,{"number":5,"repo":"me/demo"},"no_parent"]'
  assert_equal "$(jq -c .reasons <<<"$output")" '["has_parent","exceeds_max_depth"]'
  assert_equal "$(grep '^GetParent ' "$CALLS" | tr '\n' ,)" "GetParent 12,GetParent 5,"
}

@test "上限を超えると分かったら、それより上の親はたどらない" {
  setup_fake_gh
  set_parent 12 5
  set_parent 5 2
  set_parent 2 1
  # 上限 3・子だけ：候補の上に親が 2 個あれば超えるので、2 回で止める。depth は上限を超えた値（実際の 5 ではなく 4）
  run_script parent-candidate.sh --issue 12 --levels 1
  assert_success
  assert_equal "$(jq -c '[.depth, .exceeds_max_depth, .action]' <<<"$output")" '[4,true,"no_parent"]'
  assert_equal "$(grep -c '^GetParent ' "$CALLS")" 2
  # 孫まで紐付けるなら、親が 1 個で超えるので 1 回で止める
  : >"$CALLS"
  run_script parent-candidate.sh --issue 12 --levels 2
  assert_equal "$(jq -c '[.depth, .exceeds_max_depth, .parent.number]' <<<"$output")" '[4,true,5]'
  assert_equal "$(grep -c '^GetParent ' "$CALLS")" 1
  # 紐付ける層だけで上限に届いていても、親の有無を知るために 1 回はたどる
  : >"$CALLS"
  max_depth 1
  run_script parent-candidate.sh --issue 12 --levels 3
  assert_equal "$(jq -c '[.depth, .has_parent, .exceeds_max_depth]' <<<"$output")" '[5,true,true]'
  assert_equal "$(grep -c '^GetParent ' "$CALLS")" 1
}

@test "別のリポジトリの親を持つときも、親を持つとみなす" {
  setup_fake_gh
  set_parent 12 7 other/repo
  run_script parent-candidate.sh --issue 12 --levels 1
  assert_success
  assert_equal "$(jq -c '[.parent, .has_parent, .action]' <<<"$output")" '[{"number":7,"repo":"other/repo"},true,"no_parent"]'
}

@test "所有者の名前が repos でも、リポジトリを正しく読む" {
  setup_fake_gh
  export FAKE_REPO=repos/demo
  issue_json repos/demo 12 >"$FIX/issue-12.json"
  set_parent 12 5 repos/demo
  run_script parent-candidate.sh --issue 12 --levels 1
  assert_success
  assert_equal "$(jq -c .parent <<<"$output")" '{"number":5,"repo":"repos/demo"}'
  assert_equal "$(grep '^GetSubIssues ' "$CALLS")" "GetSubIssues repos/repos/demo/issues/12/sub_issues?per_page=1"
  # 親の親も、正しいパスでたどる
  assert_equal "$(grep '^GetParent ' "$CALLS" | tr '\n' ,)" "GetParent 12,GetParent 5,"
}

@test "サブ Issue は閉じた子も含めて、有無を見る" {
  setup_fake_gh
  jq -n '[{number: 20, state: "closed"}, {number: 21, state: "closed"}]' >"$FIX/sub-issues-12.json"
  run_script parent-candidate.sh --issue 12 --levels 1
  assert_success
  assert_equal "$(jq -c '[.has_sub_issues, .action, has("sub_issues")]' <<<"$output")" '[true,"no_parent",false]'
}

@test "sub_issues.max_depth に合わせて判定する（上限 2 なら孫まで紐付けると超え、上限 1 なら子も紐付けられない）" {
  setup_fake_gh
  max_depth 2
  run_script parent-candidate.sh --issue 12 --levels 1
  assert_equal "$(jq -c '[.depth, .max_depth, .action]' <<<"$output")" '[2,2,"use_as_parent"]'
  run_script parent-candidate.sh --issue 12 --levels 2
  assert_equal "$(jq -c '[.depth, .max_depth, .action]' <<<"$output")" '[3,2,"no_parent"]'
  max_depth 1
  run_script parent-candidate.sh --issue 12 --levels 1
  assert_equal "$(jq -c '[.depth, .max_depth, .reasons]' <<<"$output")" '[2,1,["exceeds_max_depth"]]'
}

@test "sub_issues.max_depth が 1・2・3 のどれでもなければ止まる" {
  setup_fake_gh
  for v in 0 4 '"2"' null; do
    max_depth "$v"
    run_script parent-candidate.sh --issue 12 --levels 1
    assert_failure 2
    assert_output --partial "sub_issues.max_depth は 1・2・3 のどれかにしてください"
  done
}

@test "候補の Issue が無いか、PR の番号なら止まる" {
  setup_fake_gh
  run_script parent-candidate.sh --issue 99 --levels 1
  assert_failure 1
  assert_output --partial "親にする候補の Issue #99 がありません（me/demo）"
  jq '. + {pull_request: {}}' "$FIX/issue-12.json" >"$FIX/i" && mv "$FIX/i" "$FIX/issue-12.json"
  run_script parent-candidate.sh --issue 12 --levels 1
  assert_failure 1
  assert_output --partial "親にする候補の Issue #12 がありません"
}

@test "サブ Issue や親を読めなければ止まる（404 以外の失敗）" {
  setup_fake_gh
  FAKE_FAIL=GetSubIssues run_script parent-candidate.sh --issue 12 --levels 1
  assert_failure
  assert_output --partial "#12 のサブ Issue を読めませんでした"
  FAKE_FAIL=GetParent FAKE_FAIL_MSG='gh: Server Error (HTTP 500)' run_script parent-candidate.sh --issue 12 --levels 1
  assert_failure
  assert_output --partial "GitHub の API に失敗しました"
}

@test "引数の誤りは 64 で止まり、--levels は必須で 1〜7 に限り、--issue は #N も受け取る" {
  setup_fake_gh
  run_script parent-candidate.sh
  assert_failure 64
  run_script parent-candidate.sh --issue
  assert_failure 64
  run_script parent-candidate.sh --issue 12 --levels 1 --bogus
  assert_failure 64
  # --levels を省くと、既定の層の数で判定せずに止まる（孫のある案で渡し忘れないように）
  run_script parent-candidate.sh --issue 12
  assert_failure 64
  assert_output --partial "--levels は必須です"
  # 大きな値で算術があふれて depth が負になり、親にすると判定しないように
  for v in 0 8 -1 x 01 1.5 99999999999999999999 ''; do
    run_script parent-candidate.sh --issue 12 --levels "$v"
    assert_failure 64
  done
  run_script parent-candidate.sh --issue 12 --levels 7
  assert_success
  assert_equal "$(jq -c '[.depth, .exceeds_max_depth]' <<<"$output")" '[8,true]'
  run_script parent-candidate.sh --issue '#012' --levels 1
  assert_success
  assert_equal "$(jq .issue <<<"$output")" 12
}
