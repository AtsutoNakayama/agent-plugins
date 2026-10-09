#!/usr/bin/env bats

load test_helper
load fake_gh

# --issue で Issue の本文を読むので、偽の gh を使う。Issue #151・#7・#9 は、本文が空の Issue にしておく
setup() {
  test_helper_setup
  setup_fake_gh
  echo '{}' >.claude/dev-workflow/config.json
  for n in 151 7 9; do fake_issue "$n" '["feat"]'; done
}

# ADR を1つ書く。使い方: write_adr <パス> <front matter の行（改行区切り。空なら front matter なし）> [見出し]
write_adr() {
  mkdir -p "$(dirname "$1")"
  {
    if [ -n "$2" ]; then
      printf -- '---\n%s\n---\n\n' "$2"
    fi
    if [ -n "${3:-}" ]; then
      printf '# %s\n\n本文\n' "$3"
    fi
  } >"$1"
}

@test "置き場所の ADR を、ファイル名の順に path・issue・status・title で出す" {
  write_adr docs/adr/000162-b.md "$(printf 'status: "accepted"\ndate: 2026-10-06\nissue: 162')" "ワークツリーを作らない"
  write_adr docs/adr/000001-a.md "$(printf 'status: proposed\nissue: 1')" "プラグインを1つにまとめる"
  run_script adr-list.sh
  assert_success
  assert_equal "$(jq -c '[.dir, .suggest, .issue]' <<<"$output")" '["docs/adr",true,null]'
  assert_equal "$(jq -c '.adrs' <<<"$output")" \
    '[{"path":"docs/adr/000001-a.md","issue":1,"status":"proposed","title":"プラグインを1つにまとめる"},{"path":"docs/adr/000162-b.md","issue":162,"status":"accepted","title":"ワークツリーを作らない"}]'
}

@test "--issue で、front matter の issue が同じ ADR だけを出す（ファイル名ではなく front matter で見る）" {
  write_adr docs/adr/000151-first.md "issue: 151" "一つ目"
  write_adr docs/adr/000151-second.md "issue: 151" "二つ目"
  write_adr docs/adr/000015-other.md "issue: 15" "別の Issue"
  # 過去の判断を後から残した ADR は、ファイル名と issue が同じとは限らない
  write_adr docs/adr/000200-late.md "issue: 1510" "桁が違う"
  write_adr docs/adr/000300-backfill.md "issue: 151" "後から残した判断"
  run_script adr-list.sh --issue "#0151"
  assert_success
  assert_equal "$(jq -c '.issue' <<<"$output")" 151
  assert_equal "$(jq -c '[.adrs[].path]' <<<"$output")" \
    '["docs/adr/000151-first.md","docs/adr/000151-second.md","docs/adr/000300-backfill.md"]'
}

@test "--issue に当たる ADR が無ければ adrs は空" {
  write_adr docs/adr/000001-a.md "issue: 1" "a"
  run_script adr-list.sh --issue 151
  assert_success
  assert_equal "$(jq -c '.adrs' <<<"$output")" '[]'
}

@test "置き場所が無ければ adrs は空" {
  run_script adr-list.sh --issue 151
  assert_success
  assert_equal "$(jq -c '[.dir, .adrs]' <<<"$output")" '["docs/adr",[]]'
}

@test "issue の値の引用符・# と先頭の 0 は外し、数字でなければ null にする" {
  write_adr docs/adr/a.md "issue: \"#007\"" "引用符と #"
  write_adr docs/adr/b.md "issue: '7'" "一重引用符"
  write_adr docs/adr/c.md "issue: {この判断をした Issue の番号。例：107}" "テンプレートのまま"
  write_adr docs/adr/d.md "issue: 0" "0"
  write_adr docs/adr/e.md "status: accepted" "issue が無い"
  run_script adr-list.sh
  assert_success
  assert_equal "$(jq -c '[.adrs[].issue]' <<<"$output")" '[7,7,null,null,null]'
  run_script adr-list.sh --issue 7
  assert_success
  assert_equal "$(jq -c '[.adrs[].path]' <<<"$output")" '["docs/adr/a.md","docs/adr/b.md"]'
}

@test "front matter の外の issue: は読まず、front matter の中の「# 」の行は見出しにしない" {
  # full のテンプレートは、front matter の中に「# 以下は任意のメタデータです。…」の行がある
  write_adr docs/adr/a.md "$(printf '# 以下は任意のメタデータです。\nstatus: accepted')" "見出し"
  printf 'issue: 9\n' >>docs/adr/a.md
  run_script adr-list.sh
  assert_success
  assert_equal "$(jq -c '.adrs' <<<"$output")" '[{"path":"docs/adr/a.md","issue":null,"status":"accepted","title":"見出し"}]'
}

@test "front matter も見出しも無いファイル（README など）は、issue・status・title を null にして出す" {
  write_adr docs/adr/README.md "" ""
  echo "ADR の置き場所" >docs/adr/README.md
  : >docs/adr/empty.md
  run_script adr-list.sh
  assert_success
  # 並びは文字の順（大文字が先）で、ロケールに左右されない
  assert_equal "$(jq -c '.adrs' <<<"$output")" \
    '[{"path":"docs/adr/README.md","issue":null,"status":null,"title":null},{"path":"docs/adr/empty.md","issue":null,"status":null,"title":null}]'
}

@test "置き場所の下のディレクトリと、.md 以外のファイルは読まない" {
  write_adr docs/adr/sub/000151-x.md "issue: 151" "下のディレクトリ"
  write_adr docs/adr/000151-x.txt "issue: 151" "md ではない"
  run_script adr-list.sh --issue 151
  assert_success
  assert_equal "$(jq -c '.adrs' <<<"$output")" '[]'
}

@test "置き場所を adr.dir で変えられる" {
  echo '{"adr": {"dir": "doc/decisions/"}}' >.claude/dev-workflow/config.json
  write_adr doc/decisions/000151-x.md "issue: 151" "x"
  write_adr docs/adr/000151-y.md "issue: 151" "y"
  run_script adr-list.sh --issue 151
  assert_success
  assert_equal "$(jq -c '[.dir, [.adrs[].path]]' <<<"$output")" '["doc/decisions",["doc/decisions/000151-x.md"]]'
}

@test "adr.dir が絶対パスや .. を含むときは止まる" {
  for d in /tmp/adr .. ../adr docs/.. docs/../adr "" /; do
    echo "{\"adr\": {\"dir\": \"$d\"}}" >.claude/dev-workflow/config.json
    run_script adr-list.sh
    assert_failure 2
    assert_output --partial "adr.dir"
  done
}

@test "suggest は設定の adr.suggest。書いていない・null なら true、false なら false" {
  run_script adr-list.sh
  assert_success
  assert_equal "$(jq -c .suggest <<<"$output")" true
  echo '{"adr": {"suggest": null}}' >.claude/dev-workflow/config.json
  run_script adr-list.sh
  assert_success
  assert_equal "$(jq -c .suggest <<<"$output")" true
  echo '{"adr": {"suggest": false}}' >.claude/dev-workflow/config.json
  run_script adr-list.sh
  assert_success
  assert_equal "$(jq -c '[.suggest, .dir]' <<<"$output")" '[false,"docs/adr"]'
}

@test "adr.suggest が true・false でなければ止まる" {
  for v in '"no"' 0 '[]'; do
    echo "{\"adr\": {\"suggest\": $v}}" >.claude/dev-workflow/config.json
    run_script adr-list.sh
    assert_failure 2
    assert_output --partial "adr.suggest は true か false"
  done
}

@test "--issue に番号でない値を渡すと止まる" {
  for v in abc 0 "#"; do
    run_script adr-list.sh --issue "$v"
    assert_failure 64
  done
  run_script adr-list.sh --issue
  assert_failure 64
  run_script adr-list.sh --foo
  assert_failure 64
}

@test "git のリポジトリの外では止まる" {
  cd "$TMP"
  run_script adr-list.sh
  assert_failure 2
  assert_output --partial "リポジトリの中ではありません"
}

@test "設定を読めなければ止まる" {
  echo '{' >.claude/dev-workflow/config.json
  run_script adr-list.sh
  assert_failure 2
  assert_output --partial "設定を読めません"
}

@test "前のファイルの値を次のファイルに持ち越さない（中身の無いファイルを挟んでも）" {
  write_adr docs/adr/a.md "$(printf 'status: accepted\nissue: 5')" "A"
  : >docs/adr/b.md
  write_adr docs/adr/c.md "" "front matter の無い C"
  write_adr docs/adr/d.md "status: proposed" ""
  run_script adr-list.sh
  assert_success
  assert_equal "$(jq -c '[.adrs[] | [.path, .issue, .status, .title]]' <<<"$output")" \
    '[["docs/adr/a.md",5,"accepted","A"],["docs/adr/b.md",null,null,null],["docs/adr/c.md",null,null,"front matter の無い C"],["docs/adr/d.md",null,"proposed",null]]'
}

@test "改行が \r\n の ADR と、先頭に BOM がある ADR も読む" {
  mkdir -p docs/adr
  printf -- '---\r\nstatus: "accepted"\r\nissue: 151\r\n---\r\n\r\n# CRLF\r\n' >docs/adr/000151-crlf.md
  printf -- '\357\273\277---\nstatus: accepted\nissue: 151\n---\n\n# BOM\n' >docs/adr/000151-bom.md
  run_script adr-list.sh --issue 151
  assert_success
  assert_equal "$(jq -c '.adrs' <<<"$output")" \
    '[{"path":"docs/adr/000151-bom.md","issue":151,"status":"accepted","title":"BOM"},{"path":"docs/adr/000151-crlf.md","issue":151,"status":"accepted","title":"CRLF"}]'
}

@test "引用符で囲んでいない値の、空白の後の # からのコメントは外す" {
  write_adr docs/adr/a.md "$(printf 'status: accepted  # 決めた\nissue: 151 # 後から残した')" "a"
  # 引用符で囲まない #151 は、YAML ではコメント（値なし）なので、# を付けるなら囲む
  write_adr docs/adr/b.md "$(printf 'status: \"a # b\"\nissue: \"#151\"')" "b"
  run_script adr-list.sh --issue 151
  assert_success
  assert_equal "$(jq -c '[.adrs[] | [.path, .status]]' <<<"$output")" '[["docs/adr/a.md","accepted"],["docs/adr/b.md","a # b"]]'
}

@test "--issue が無ければ、proposal と adr_tasks は null で、Issue を読まない" {
  run_script adr-list.sh
  assert_success
  assert_equal "$(jq -c '[.proposal, .adr_tasks]' <<<"$output")" '[null,null]'
  assert_equal "$(called issue-view)" 0
}

@test "proposal：adr.suggest が false なら disabled、その Issue の ADR があれば exists で、どちらも Issue を読まない" {
  fake_issue_body 151 "$(printf -- '- [ ] 判断を ADR に残す')"
  echo '{"adr": {"suggest": false}}' >.claude/dev-workflow/config.json
  run_script adr-list.sh --issue 151
  assert_success
  assert_equal "$(jq -c '[.proposal, .adr_tasks]' <<<"$output")" '["disabled",null]'
  echo '{}' >.claude/dev-workflow/config.json
  write_adr docs/adr/000151-x.md "issue: 151" "x"
  run_script adr-list.sh --issue 151
  assert_success
  assert_equal "$(jq -c '[.proposal, .adr_tasks]' <<<"$output")" '["exists",null]'
  assert_equal "$(called issue-view)" 0
}

@test "proposal：ADR の項目が無ければ judge（ADR を含まない項目と、コードブロックの中の項目は数えない）" {
  # shellcheck disable=SC2016 # ``` はコードブロックの囲みで、展開させない
  fake_issue_body 151 "$(printf -- '## やること\n- [ ] 実装する\n```\n- [ ] 判断を ADR に残す\n```')"
  run_script adr-list.sh --issue 151
  assert_success
  assert_equal "$(jq -c '[.proposal, .adr_tasks]' <<<"$output")" '["judge",[]]'
  assert_equal "$(args issue-view)" "151 --json url,body"
}

@test "proposal：取り消し線もチェックも無い ADR の項目があれば pending（ほかの項目が断った記録やチェック済みでも）" {
  fake_issue_body 151 "$(printf -- '- [ ] ~~一つ目を ADR に残す~~（不要）\n- [x] 二つ目を ADR に残す\n- [ ] 三つ目を ADR に残す')"
  run_script adr-list.sh --issue 151
  assert_success
  assert_equal "$(jq -c .proposal <<<"$output")" '"pending"'
  assert_equal "$(jq -c '[.adr_tasks[].text]' <<<"$output")" '["~~一つ目を ADR に残す~~（不要）","二つ目を ADR に残す","三つ目を ADR に残す"]'
}

@test "proposal：取り消し線の無い ADR の項目がすべてチェック済みなら done" {
  fake_issue_body 151 "$(printf -- '- [ ] ~~一つ目を ADR に残す~~（不要）\n- [x] 二つ目を ADR に残す')"
  run_script adr-list.sh --issue 151
  assert_success
  assert_equal "$(jq -c .proposal <<<"$output")" '"done"'
}

@test "proposal：ADR の項目が取り消し線だけなら（チェックがあっても）declined" {
  fake_issue_body 151 "$(printf -- '- [ ] ~~一つ目を ADR に残す~~（不要）\n- [x] ~~二つ目を ADR に残す~~')"
  run_script adr-list.sh --issue 151
  assert_success
  assert_equal "$(jq -c .proposal <<<"$output")" '"declined"'
  # 途中だけの取り消し線は、断った記録とみなさない
  fake_issue_body 151 "$(printf -- '- [ ] ~~判断~~を ADR に残す')"
  run_script adr-list.sh --issue 151
  assert_equal "$(jq -c .proposal <<<"$output")" '"pending"'
}

@test "--issue が PR の番号か無い番号なら止まる" {
  run_script adr-list.sh --issue 404
  assert_failure 2
  assert_output --partial "#404 が"
}

@test "引用符で囲んだ値は閉じる引用符までを値にし、後ろのコメントは捨てる" {
  write_adr docs/adr/a.md "$(printf 'status: "accepted" # 見直し済み\nissue: "151" # 元の Issue')" "a"
  write_adr docs/adr/b.md "$(printf "status: 'a # b'  # c\nissue: '151'")" "b"
  write_adr docs/adr/c.md "$(printf 'status: "閉じていない\nissue: 151')" "c"
  run_script adr-list.sh --issue 151
  assert_success
  assert_equal "$(jq -c '[.adrs[] | [.path, .status]]' <<<"$output")" '[["docs/adr/a.md","accepted"],["docs/adr/b.md","a # b"],["docs/adr/c.md","\"閉じていない"]]'
}

@test "proposal：ADR を話題にしているだけの項目（「ADR に残す」を含まない）は ADR の項目とみなさず、judge にする" {
  fake_issue_body 151 "$(printf -- '- [ ] ADR-0005 の手順に従って実装する\n- [x] 既に ADR がある判断は提案しない\n- [ ] README の ADR の節を直す')"
  run_script adr-list.sh --issue 151
  assert_success
  assert_equal "$(jq -c '[.proposal, .adr_tasks]' <<<"$output")" '["judge",[]]'
}

@test "Issue を読むときに --issue が PR の番号なら終了コード 2、読めなければ 1 で止まる（disabled・exists では読まない）" {
  jq -n '{number: 21, url: "https://github.com/me/demo/pull/21", title: "PR", state: "OPEN", labels: [], body: ""}' >"$FIX/issue-21.json"
  run_script adr-list.sh --issue 21
  assert_failure 2
  assert_output --partial "#21 は PR です"
  FAKE_FAIL=issue-view run_script adr-list.sh --issue 151
  assert_failure 1
  assert_output --partial "#151 を読めません"
  # Issue を読まないときは、PR の番号でも止まらない
  echo '{"adr": {"suggest": false}}' >.claude/dev-workflow/config.json
  run_script adr-list.sh --issue 21
  assert_success
  assert_equal "$(jq -c .proposal <<<"$output")" '"disabled"'
}

@test "値の引用符の中のエスケープを元の文字に戻し、空の引用符は値なしにする（閉じていない引用符の値は、YAML として正しくないので読めない）" {
  write_adr docs/adr/a.md "$(printf "status: 'won''t fix'  # c\nissue: '151'")" "a"
  write_adr docs/adr/b.md "$(printf 'status: "see \\"X\\" # y" # z\nissue: 151')" "b"
  write_adr docs/adr/c.md "$(printf 'status: "" # 未定\nissue: '"''")" "c"
  write_adr docs/adr/d.md "$(printf 'status: accepted\nissue: "151')" "d"
  run_script adr-list.sh
  assert_success
  assert_equal "$(jq -c '[.adrs[] | [.path, .issue, .status]]' <<<"$output")" \
    '[["docs/adr/a.md",151,"won'"'"'t fix"],["docs/adr/b.md",151,"see \"X\" # y"],["docs/adr/c.md",null,null],["docs/adr/d.md",null,"accepted"]]'
}

@test "ADR の項目は「ADR」と「に残す」の間の空白（無い・全角）を問わず、取り消し線は「ADR に残す」が ~~ の内側にあるかで見る" {
  fake_issue_body 151 "$(printf -- '- [ ] 設定の判断をADRに残す')"
  run_script adr-list.sh --issue 151
  assert_equal "$(jq -c '[.proposal, [.adr_tasks[].text]]' <<<"$output")" '["pending",["設定の判断をADRに残す"]]'
  fake_issue_body 151 "$(printf -- '- [ ] 設定の判断を ADR　に残す')"
  run_script adr-list.sh --issue 151
  assert_equal "$(jq -c .proposal <<<"$output")" '"pending"'
  # 「ADR に残す」だけを取り消した断った記録
  fake_issue_body 151 "$(printf -- '- [ ] 設定の判断を ~~ADRに残す~~（不要）')"
  run_script adr-list.sh --issue 151
  assert_equal "$(jq -c .proposal <<<"$output")" '"declined"'
  # 取り消し線はあるが、「ADR に残す」は取り消し線の外にある
  fake_issue_body 151 "$(printf -- '- [ ] ~~旧案~~ではなく新案の判断を ADR に残す（~~別 Issue~~ ではない）')"
  run_script adr-list.sh --issue 151
  assert_equal "$(jq -c .proposal <<<"$output")" '"pending"'
  # 閉じていない ~~ の後ろは、取り消し線の内側とみなさない
  fake_issue_body 151 "$(printf -- '- [ ] 判断を ~~ADR に残す')"
  run_script adr-list.sh --issue 151
  assert_equal "$(jq -c .proposal <<<"$output")" '"pending"'
}

@test "Issue の本文が長くても（引数の長さの上限を超える大きさでも）読める" {
  # 日本語は UTF-8 で1文字3バイトなので、6万文字で 180KB ほどになる（Linux の引数1つの上限は 128KiB）
  body="$(printf -- '- [ ] 判断を ADR に残す\n'; head -c 60000 /dev/zero | tr '\0' 'x' | sed 's/x/あ/g')"
  fake_issue_body 151 "$body"
  run_script adr-list.sh --issue 151
  assert_success
  assert_equal "$(jq -c .proposal <<<"$output")" '"pending"'
}

@test "見出しが2つ以上ある ADR は最初の見出しを title にし、残りを読まずに次のファイルへ進む" {
  mkdir -p docs/adr
  printf -- '---\nissue: 151\n---\n\n# 一つ目\n\n## 節\n\n# 二つ目\n---\nissue: 9\n---\n' >docs/adr/a.md
  write_adr docs/adr/b.md "$(printf 'status: accepted\nissue: 151')" "B"
  run_script adr-list.sh --issue 151
  assert_success
  assert_equal "$(jq -c '[.adrs[] | [.path, .issue, .status, .title]]' <<<"$output")" \
    '[["docs/adr/a.md",151,null,"一つ目"],["docs/adr/b.md",151,"accepted","B"]]'
}

@test "取り消し線は ~ 1つでも見て、「ADR に残す」が取り消し線の内側と外側の両方にあれば、断った記録とみなさない" {
  # GitHub は ~1つ~ も取り消し線として表示する
  fake_issue_body 151 "$(printf -- '- [ ] ~判断を ADR に残す~（不要）')"
  run_script adr-list.sh --issue 151
  assert_equal "$(jq -c .proposal <<<"$output")" '"declined"'
  fake_issue_body 151 "$(printf -- '- [ ] ~~旧案を ADR に残す~~ 新案を ADR に残す')"
  run_script adr-list.sh --issue 151
  assert_equal "$(jq -c .proposal <<<"$output")" '"pending"'
}

@test "ADR が多くても（パスの一覧が引数の長さの上限の 128 KiB を超えても）止まらない" {
  mkdir -p docs/adr
  (cd docs/adr && for i in $(seq 1 1800); do
    : >"$(printf '%06d-a-long-name-of-the-decision-to-make-the-list-of-paths-long.md' "$i")"
  done)
  printf -- '---\nissue: 151\n---\n\n# 最後\n' >docs/adr/999999-last.md
  run_script adr-list.sh
  assert_success
  assert_equal "$(jq -c '[(.adrs | length), .adrs[-1].issue, .adrs[-1].title]' <<<"$output")" '[1801,151,"最後"]'
}

@test "ADR の見出しが長く絵文字を含んでも（4096 バイトを超える1行で、読み込みの区切りにまたがっても）壊さずに出す" {
  # 標準入力の jq -R は、4096 バイトを超える1行（長い見出し）の、読み込みの区切りにまたがる BMP の外の文字（絵文字）を壊すので、使わない
  mkdir -p docs/adr
  emoji="$(printf '😀%.0s' $(seq 1 15))"
  (cd docs/adr && for i in 1 2 3; do : >"$(printf '%06d-%s.md' "$i" "$emoji")"; done)
  title="$(printf 'ab😀%.0s' $(seq 1 3000))"
  printf -- '---\nissue: 151\n---\n\n# %s\n' "$title" >docs/adr/999999-last.md
  run_script adr-list.sh
  assert_success
  assert_equal "$(jq -c '[(.adrs | length), ([.. | strings | select(test("\uFFFD"))] | length)]' <<<"$output")" '[4,0]'
  assert_equal "$(jq -r '.adrs[0].path' <<<"$output")" "docs/adr/000001-${emoji}.md"
  assert_equal "$(jq -r '.adrs[-1].title' <<<"$output")" "$title"
}
