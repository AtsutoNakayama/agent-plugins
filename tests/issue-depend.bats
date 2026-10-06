#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper

# 偽の gh。
# - gh repo view ... -q .nameWithOwner                       me/demo を返す
# - gh api repos/me/demo/issues/<番号>                       $FIX/issue-<番号>.json を返す（無ければ 404）。「GetIssue <番号>」を記録する
# - gh api --paginate .../issues/<番号>/dependencies/blocked_by...  $FIX/blocked-<番号>.json（無ければ []）を返す。「Blocked <番号>」を記録する
# - gh api -X POST .../issues/<番号>/dependencies/blocked_by -F issue_id=<id>  「AddBlockedBy <番号> <id>」を記録する
# - gh issue edit <番号> --body-file -                        標準入力を $FIX/body-<番号> に書き、「EditBody <番号>」を記録する
# FAKE_FAIL に指定した操作名（GetIssue・Blocked・AddBlockedBy・EditBody）は、FAKE_FAIL_MSG（既定: gh: failed）を出して失敗する。
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
  "api --paginate")
    n="${3#*/issues/}"
    n="${n%%/*}"
    echo "Blocked $n" >>"$CALLS"
    fail Blocked
    if [ -f "$FIX/blocked-$n.json" ]; then cat "$FIX/blocked-$n.json"; else echo '[]'; fi
    ;;
  "api -X")
    n="${4%/dependencies/blocked_by}"
    echo "AddBlockedBy ${n##*/} ${6#issue_id=}" >>"$CALLS"
    fail AddBlockedBy
    echo '{}'
    ;;
  "api repos/me/demo/issues/"*)
    n="${2##*/}"
    echo "GetIssue $n" >>"$CALLS"
    fail GetIssue
    [ -f "$FIX/issue-$n.json" ] || { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
    cat "$FIX/issue-$n.json"
    ;;
  "issue edit")
    echo "EditBody $3" >>"$CALLS"
    fail EditBody
    cat >"$FIX/body-$3"
    ;;
  *) echo "gh: 想定外の呼び出し: $*" >&2; exit 1 ;;
esac
SH
  chmod +x "$TMP/bin/gh"
  export PATH="$TMP/bin:$PATH"
}

# 使い方: issue <番号> [本文] [PR なら pr] [状態（既定 open）]
# REST の Issue を書く。id は番号に 1000 を足したもの
issue() {
  jq -nc --argjson n "$1" --arg b "${2-}" --arg pr "${3:-}" --arg st "${4:-open}" '{number: $n, id: ($n + 1000), body: $b, state: $st,
    html_url: "https://github.com/me/demo/issues/\($n)"} + (if $pr == "" then {} else {pull_request: {}} end)' >"$FIX/issue-$1.json"
}

called() { grep -c "^$1 " "$CALLS" || true; }
body_of() { cat "$FIX/body-$1"; }

@test "GitHub の依存関係に登録し、本文の「依存」の「- なし」を「- #N」に置き換える" {
  setup_fake_gh
  issue 10 $'## 背景\nx\n\n## 依存\n- なし\n'
  issue 5
  run_script issue-depend.sh --issue 10 --blocked-by 5
  assert_success
  assert_equal "$(grep '^AddBlockedBy ' "$CALLS")" 'AddBlockedBy 10 1005'
  assert_equal "$(body_of 10)" $'## 背景\nx\n\n## 依存\n- #5'
  assert_equal "$(jq -c '[.issue, .blocked_by, .added, .dry_run]' <<<"$output")" '[10,[5],{"dependency":[5],"body":[5]},false]'
}

@test "既にある依存の後ろ（次の見出しの前）に足し、空行はそのまま残す。番号は重複を除き、#N でもよい" {
  setup_fake_gh
  issue 10 $'## 依存\n- #3\n\n## 補足\ny'
  issue 3
  issue 5
  issue 6
  echo '[{"id": 1003}]' >"$FIX/blocked-10.json"
  run_script issue-depend.sh --issue '#10' --blocked-by 5 --blocked-by '#6' --blocked-by 05
  assert_success
  assert_equal "$(body_of 10)" $'## 依存\n- #3\n- #5\n- #6\n\n## 補足\ny'
  assert_equal "$(grep '^AddBlockedBy ' "$CALLS" | cut -d' ' -f3 | tr '\n' ' ')" '1005 1006 '
}

@test "既に依存関係にも本文にもある依存は、足さない（何度実行しても同じ）" {
  setup_fake_gh
  issue 10 $'## 依存\n- #5（先に API を作る）'
  issue 5
  echo '[{"id": 1005}]' >"$FIX/blocked-10.json"
  run_script issue-depend.sh --issue 10 --blocked-by 5
  assert_success
  assert_equal "$(called AddBlockedBy)" 0
  assert_equal "$(called EditBody)" 0
  assert_equal "$(jq -c .added <<<"$output")" '{"dependency":[],"body":[]}'
}

@test "依存関係にだけある・本文にだけある依存は、無いほうにだけ足す" {
  setup_fake_gh
  issue 10 $'## 依存\n- #5'
  issue 11 $'## 依存\n- なし'
  issue 5
  run_script issue-depend.sh --issue 10 --blocked-by 5
  assert_success
  assert_equal "$(jq -c .added <<<"$output")" '{"dependency":[5],"body":[]}'
  echo '[{"id": 1005}]' >"$FIX/blocked-11.json"
  run_script issue-depend.sh --issue 11 --blocked-by 5
  assert_success
  assert_equal "$(jq -c .added <<<"$output")" '{"dependency":[],"body":[5]}'
}

@test "本文に「依存」の見出しが無ければ、本文の最後に足す（本文が空なら見出しから書く）" {
  setup_fake_gh
  issue 10 $'## 背景\nx\n\n'
  issue 11 ''
  issue 5
  run_script issue-depend.sh --issue 10 --blocked-by 5
  assert_success
  assert_equal "$(body_of 10)" $'## 背景\nx\n\n## 依存\n- #5'
  run_script issue-depend.sh --issue 11 --blocked-by 5
  assert_success
  assert_equal "$(body_of 11)" $'## 依存\n- #5'
}

@test "バッククォートで囲んだ「なし」も消し、見出しの外の #N は既にある依存として数えない" {
  setup_fake_gh
  issue 10 $'## 背景\n#5 の後で\n\n## 依存\n- `なし`'
  issue 5
  run_script issue-depend.sh --issue 10 --blocked-by 5
  assert_success
  assert_equal "$(body_of 10)" $'## 背景\n#5 の後で\n\n## 依存\n- #5'
}

@test "行末が CRLF の本文では、足す行も CRLF にする" {
  setup_fake_gh
  issue 10 $'## 依存\r\n- なし\r\n\r\n## 補足\r\ny'
  issue 5
  run_script issue-depend.sh --issue 10 --blocked-by 5
  assert_success
  assert_equal "$(body_of 10)" $'## 依存\r\n- #5\r\n\r\n## 補足\r\ny'
}

@test "Issue や依存する Issue が無い・PR の番号なら、何も変えずに止まる" {
  setup_fake_gh
  issue 10
  issue 7 '' pr
  run_script issue-depend.sh --issue 10 --blocked-by 99
  assert_failure 2
  assert_output --partial "依存する Issue #99 がありません（me/demo）"
  run_script issue-depend.sh --issue 10 --blocked-by 7
  assert_failure 2
  assert_output --partial "依存する Issue #7 がありません"
  run_script issue-depend.sh --issue 7 --blocked-by 10
  assert_failure 2
  assert_output --partial "Issue #7 がありません"
  assert_equal "$(grep -cvE '^GetIssue ' "$CALLS")" 0
}

@test "Issue を 404 以外の理由で読めなければ、GitHub の理由を伝えて止まる" {
  setup_fake_gh
  issue 10
  FAKE_FAIL=GetIssue FAKE_FAIL_MSG="gh: Server Error (HTTP 500)" run_script issue-depend.sh --issue 10 --blocked-by 5
  assert_failure 1
  assert_output --partial "gh: Server Error (HTTP 500)"
}

@test "--dry-run では変えず、行う予定の操作を出す" {
  setup_fake_gh
  issue 10 $'## 依存\n- なし'
  issue 5
  run_script issue-depend.sh --issue 10 --blocked-by 5 --dry-run
  assert_success
  assert_equal "$(called AddBlockedBy)" 0
  assert_equal "$(called EditBody)" 0
  assert_equal "$(jq -c '[.dry_run, .actions]' <<<"$output")" \
    '[true,["Issue #10 の依存関係（blocked by）に #5 を登録する","Issue #10 の本文の「依存」に #5 を書く"]]'
}

@test "本文を書き換えられなければ、もう一度実行するよう伝えて止まる" {
  setup_fake_gh
  issue 10 $'## 依存\n- なし'
  issue 5
  FAKE_FAIL=EditBody run_script issue-depend.sh --issue 10 --blocked-by 5
  assert_failure 1
  assert_output --partial "Issue #10 の本文の「依存」を書き換えられませんでした（もう一度実行すれば書きます）"
}

@test "引数の誤りは、使い方の誤り（64）で止まる" {
  setup_fake_gh
  run_script issue-depend.sh --blocked-by 5
  assert_failure 64
  assert_output --partial "--issue は必須です"
  run_script issue-depend.sh --issue 10
  assert_failure 64
  assert_output --partial "--blocked-by は必須です"
  run_script issue-depend.sh --issue 10 --blocked-by '#10'
  assert_failure 64
  assert_output --partial "Issue #10 は自分自身に依存できません"
  run_script issue-depend.sh --issue 10 --blocked-by x
  assert_failure 64
  run_script issue-depend.sh --issue 10 --foo
  assert_failure 64
  run_script issue-depend.sh --blocked-by 5 --issue
  assert_failure 64
  assert_output --partial "--issue に値がありません"
  run_script issue-depend.sh --issue 10 --blocked-by ''
  assert_failure 64
  assert_output --partial "--blocked-by に値がありません"
  assert_equal "$(cat "$CALLS")" ''
}

@test "「## 」で始まらない行（##依存）は見出しとみなさず、next-tasks.sh と同じく節を足す" {
  # 見出しの読み方が next-tasks.sh と違い、足した依存が task-next に読まれないことがあった
  setup_fake_gh
  issue 10 $'##依存\n- なし'
  issue 5
  run_script issue-depend.sh --issue 10 --blocked-by 5
  assert_success
  assert_equal "$(body_of 10)" $'##依存\n- なし\n\n## 依存\n- #5'
}

@test "見出しが無い CRLF の本文には、CRLF で節を足す" {
  setup_fake_gh
  issue 10 $'## 背景\r\nx\r\n'
  issue 5
  run_script issue-depend.sh --issue 10 --blocked-by 5
  assert_success
  assert_equal "$(body_of 10 | od -c | tr -s ' ' | tr -d '\n')" "$(printf '## 背景\r\nx\r\n\r\n## 依存\r\n- #5\r\n' | od -c | tr -s ' ' | tr -d '\n')"
}

@test "依存関係を登録できなければ（循環などで GitHub が断ったら）、GitHub の理由を出して止まり、本文は変えない" {
  setup_fake_gh
  issue 10 $'## 依存\n- なし'
  issue 5
  FAKE_FAIL=AddBlockedBy FAKE_FAIL_MSG="gh: Validation Failed (HTTP 422)" run_script issue-depend.sh --issue 10 --blocked-by 5
  assert_failure 1
  assert_output --partial "gh: Validation Failed (HTTP 422)"
  assert_output --partial "Issue #10 の依存関係に #5 を登録できませんでした"
  assert_equal "$(called EditBody)" 0
}

@test "登録済みの依存関係を読めなければ、何も変えずに止まる" {
  setup_fake_gh
  issue 10 $'## 依存\n- なし'
  issue 5
  FAKE_FAIL=Blocked run_script issue-depend.sh --issue 10 --blocked-by 5
  assert_failure 1
  assert_output --partial "Issue #10 の依存関係を読めませんでした"
  assert_equal "$(called AddBlockedBy) $(called EditBody)" '0 0'
}

@test "Issue が閉じていれば止まり、依存する Issue が閉じていれば、警告してその Issue だけを飛ばす" {
  # 確かめた後で、着手中の Issue の PR がマージされて閉じることもある。1つが閉じただけで、ほかの依存まで足さずに止まっていた
  setup_fake_gh
  issue 10 $'## 依存\n- なし' "" closed
  issue 11 $'## 依存\n- なし'
  issue 5 "" "" closed
  issue 6
  run_script issue-depend.sh --issue 10 --blocked-by 6
  assert_failure 2
  assert_output --partial "Issue #10 は閉じています"
  assert_equal "$(called AddBlockedBy) $(called EditBody)" '0 0'
  run_script issue-depend.sh --issue 11 --blocked-by 5 --blocked-by 6
  assert_success
  assert_line "warn: 依存する Issue #5 は閉じているので、依存に足しません"
  assert_equal "$(grep -v '^warn:' <<<"$output" | jq -c '[.added, .skipped_closed]')" '[{"dependency":[6],"body":[6]},[5]]'
  assert_equal "$(body_of 11)" $'## 依存\n- #6'
}

@test "節の中身が「なし」の1行だけなら置き換え（箇条書きでなくても、理由付きでも）、その行の #N は既にある依存として数えない" {
  # 消す「なし」の行の #5 を既にあるものと数え、#5 が本文から消えていた
  setup_fake_gh
  issue 10 $'## 依存\nなし\n\n## 補足\ny'
  issue 11 $'## 依存\n- `なし`（#5 は閉じた）'
  issue 5
  issue 7
  run_script issue-depend.sh --issue 10 --blocked-by 5
  assert_success
  assert_equal "$(body_of 10)" $'## 依存\n- #5\n\n## 補足\ny'
  run_script issue-depend.sh --issue 11 --blocked-by 5 --blocked-by 7
  assert_success
  assert_equal "$(body_of 11)" $'## 依存\n- #5\n- #7'
}

@test "「なし」で始まる文や、ほかの行と並ぶ「なし」は消さず、どの「依存」の節にも無い番号だけを最初の節に足す" {
  # 「なし」で始まる使う人の文まで消していた
  setup_fake_gh
  issue 10 $'## 依存\nなしでも動くが、#3 の後が望ましい\n\n## 依存\n- #6\n- なし'
  issue 3
  issue 6
  issue 7
  run_script issue-depend.sh --issue 10 --blocked-by 3 --blocked-by 6 --blocked-by 7
  assert_success
  assert_equal "$(body_of 10)" $'## 依存\nなしでも動くが、#3 の後が望ましい\n- #7\n\n## 依存\n- #6\n- なし'
  assert_equal "$(jq -c .added.body <<<"$output")" '[7]'
}

@test "閉じていないコードブロックがあっても、「## 依存」の節を見つけ、何度実行しても節を足し続けない" {
  # 見出しをコードブロックの外に限ると、閉じていないコードブロックの後の節が見えず、実行のたびに節を足していた
  setup_fake_gh
  issue 10 $'## 背景\n```\nx\n## 依存\n- なし'
  issue 5
  run_script issue-depend.sh --issue 10 --blocked-by 5
  assert_success
  assert_equal "$(body_of 10)" $'## 背景\n```\nx\n## 依存\n- #5'
  jq --arg b "$(body_of 10)" '.body = $b' "$FIX/issue-10.json" >"$FIX/i" && mv "$FIX/i" "$FIX/issue-10.json"
  echo '[{"id": 1005}]' >"$FIX/blocked-10.json"
  run_script issue-depend.sh --issue 10 --blocked-by 5
  assert_success
  assert_equal "$(jq -c .added <<<"$output")" '{"dependency":[],"body":[]}'
}

@test "「なし」の行は、箇条書きの記号・「特に」・句点が付いていても、HTML のコメントの行と並んでいても置き換える" {
  setup_fake_gh
  issue 10 $'## 依存\n<!-- 先に終わらせる Issue -->\n- なし。'
  issue 11 $'## 依存\n+ 特になし'
  issue 12 $'## 依存\n1. なし'
  issue 5
  for n in 10 11 12; do
    run_script issue-depend.sh --issue "$n" --blocked-by 5
    assert_success
  done
  assert_equal "$(body_of 10)" $'## 依存\n<!-- 先に終わらせる Issue -->\n- #5'
  assert_equal "$(body_of 11)" $'## 依存\n- #5'
  assert_equal "$(body_of 12)" $'## 依存\n- #5'
}

@test "CRLF の本文の、改行の無い最後の行の後に足すときも、CRLF にそろえる（本文の最後には改行を足さない）" {
  setup_fake_gh
  issue 10 $'## 依存\r\n- #3'
  issue 11 $'## 依存\r\n- なし'
  issue 3
  issue 5
  run_script issue-depend.sh --issue 10 --blocked-by 5
  assert_success
  assert_equal "$(body_of 10 | od -c | tr -s ' ' | tr -d '\n')" "$(printf '## 依存\r\n- #3\r\n- #5' | od -c | tr -s ' ' | tr -d '\n')"
  run_script issue-depend.sh --issue 11 --blocked-by 5
  assert_success
  assert_equal "$(body_of 11 | od -c | tr -s ' ' | tr -d '\n')" "$(printf '## 依存\r\n- #5' | od -c | tr -s ' ' | tr -d '\n')"
}

@test "「依存」の節の中身が空なら、見出しの直後に足す" {
  setup_fake_gh
  issue 10 $'## 依存\n\n## 補足\ny'
  issue 5
  run_script issue-depend.sh --issue 10 --blocked-by 5
  assert_success
  assert_equal "$(body_of 10)" $'## 依存\n- #5\n\n## 補足\ny'
  assert_equal "$(jq -c .added.body <<<"$output")" '[5]'
}

@test "依存する Issue が全部閉じていれば、依存関係を読まず、何も変えずに skipped_closed に出す" {
  setup_fake_gh
  issue 10 $'## 依存\n- なし'
  issue 5 "" "" closed
  FAKE_FAIL=Blocked run_script issue-depend.sh --issue 10 --blocked-by 5
  assert_success
  assert_line "warn: 依存する Issue #5 は閉じているので、依存に足しません"
  assert_equal "$(grep -v '^warn:' <<<"$output" | jq -c '[.added, .skipped_closed]')" '[{"dependency":[],"body":[]},[5]]'
  assert_equal "$(called Blocked) $(called AddBlockedBy) $(called EditBody)" '0 0 0'
}
