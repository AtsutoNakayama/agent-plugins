#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper
load fake_gh

BODY='## 背景
なし

## やること
- [ ] a.sh を足す

## 完了条件
- a.sh が動く

## 依存
- なし'

# 使い方: set_config <jq の式> → チームの設定を書き換える
set_config() {
  jq "$1" .claude/dev-workflow/config.json >"$TMP/c.json" && mv "$TMP/c.json" .claude/dev-workflow/config.json
}

# task-auto を有効にし、保留の列を設定して、Issue #17（feat）に本文を入れる
setup_auto() {
  setup_fake_gh
  set_config '. + {auto: {enabled: true}, status: {hold: "On Hold"}}'
  fake_issue_body 17 "$BODY"
}

run_check() {
  run_script auto-check.sh "$@"
  printf '%s\n' "$output"
}

@test "有効で、Issue が止まる条件に当たらなければ proceed" {
  setup_auto
  run_check --issue '#17'
  assert_success
  assert_equal "$(jq -c '[.action, .reasons, .issue.number, .issue.type, .issue.breaking]' <<<"$output")" '["proceed",[],17,"feat",false]'
  assert_equal "$(jq -c .settings <<<"$output")" '{"max_fix_attempts":3,"max_new_issues":3,"hold":"On Hold"}'
}

@test "既定（auto.enabled が false）なら disabled で、Issue も読まない" {
  setup_fake_gh
  run_check --issue 17
  assert_success
  assert_equal "$(jq -c '[.action, .issue]' <<<"$output")" '["disabled",null]'
  assert_equal "$(called issue-view)" 0
}

@test "enabled が true でなければ（文字列の \"true\" でも）disabled" {
  setup_fake_gh
  set_config '. + {auto: {enabled: "true"}, status: {hold: "On Hold"}}'
  run_check --issue 17
  assert_success
  assert_equal "$(jq -r .action <<<"$output")" disabled
}

@test "保留の列が無ければ no_hold で、Issue も読まない" {
  setup_fake_gh
  set_config '. + {auto: {enabled: true}}'
  run_check --issue 17
  assert_success
  assert_equal "$(jq -r .action <<<"$output")" no_hold
  assert_output --partial "repo-setup"
  assert_equal "$(called issue-view)" 0
}

@test "保留の列がほかの役割と同じ名前なら止まる" {
  setup_auto
  set_config '.status.hold = "Todo"'
  run_check --issue 17
  assert_failure 2
  assert_output --partial "保留の列（status.hold）は、ほかの役割（status.todo）と別の列名にしてください"
}

@test "max_fix_attempts が1以上の整数でなければ、max_new_issues が0以上の整数でなければ止まる" {
  setup_auto
  for v in 0 -1 1.5 '"3"' null; do
    set_config ".auto.max_fix_attempts = $v"
    run_check --issue 17
    assert_failure 2
    assert_output --partial "auto.max_fix_attempts は1以上の整数にしてください"
  done
  set_config '.auto.max_fix_attempts = 2 | .auto.max_new_issues = 0'
  run_check --issue 17
  assert_success
  assert_equal "$(jq -c .settings <<<"$output")" '{"max_fix_attempts":2,"max_new_issues":0,"hold":"On Hold"}'
  set_config '.auto.max_new_issues = -1'
  run_check --issue 17
  assert_failure 2
  assert_output --partial "auto.max_new_issues は0以上の整数にしてください"
}

@test "閉じた Issue と親の Issue は not_startable" {
  setup_auto
  jq '.state = "CLOSED"' "$FIX/issue-17.json" >"$TMP/i.json" && mv "$TMP/i.json" "$FIX/issue-17.json"
  run_check --issue 17
  assert_success
  assert_equal "$(jq -c '[.action, .reasons]' <<<"$output")" '["not_startable",["Issue #17 は閉じています"]]'
  jq '.state = "OPEN" | .subIssuesSummary = {total: 2}' "$FIX/issue-17.json" >"$TMP/i.json" && mv "$TMP/i.json" "$FIX/issue-17.json"
  run_check --issue 17
  assert_equal "$(jq -r .action <<<"$output")" not_startable
  assert_output --partial "親の Issue（サブ Issue が 2 件）"
}

@test "breaking ラベル（大文字でも）と、type ラベルが1つでないことは hold の理由になる" {
  setup_auto
  fake_issue 17 '["feat", "Breaking"]'
  fake_issue_body 17 "$BODY"
  run_check --issue 17
  assert_success
  assert_equal "$(jq -c '[.action, .issue.breaking, (.reasons | length)]' <<<"$output")" '["hold",true,1]'
  assert_output --partial "breaking ラベルが付いています"
  fake_issue 17 '["feat", "fix"]'
  fake_issue_body 17 "$BODY"
  run_check --issue 17
  assert_equal "$(jq -c '[.action, .issue.type]' <<<"$output")" '["hold",null]'
  assert_output --partial "type ラベルが1つではありません（今は feat, fix）"
  fake_issue 17 '[]'
  fake_issue_body 17 "$BODY"
  run_check --issue 17
  assert_output --partial "type ラベルがありません"
}

@test "「やること」「完了条件」が無い・テンプレートのままなら hold の理由になる" {
  setup_auto
  fake_issue_body 17 '## 背景
何か

## やること
- [ ]

## 完了条件
-
'
  run_check --issue 17
  assert_success
  assert_equal "$(jq -r .action <<<"$output")" hold
  assert_equal "$(jq -r '.reasons | length' <<<"$output")" 2
  assert_output --partial "本文の「やること」に項目がありません"
  assert_output --partial "本文の「完了条件」に項目がありません"
  fake_issue_body 17 '何かを直す'
  run_check --issue 17
  assert_equal "$(jq -r '.reasons | length' <<<"$output")" 2
}

@test "コードブロックと HTML のコメントの中の見出しや項目は数えない" {
  setup_auto
  fake_issue_body 17 '## やること
<!-- - [ ] コメントの中
-->
```
## 完了条件
- コードの中
```
- [ ] 本当の項目'
  run_check --issue 17
  assert_equal "$(jq -c .reasons <<<"$output")" '["本文の「完了条件」に項目がありません（どこまでやれば終わりかが決まっていません）"]'
}

@test "英語の見出し（Tasks・Acceptance criteria。大文字と小文字は問わない）と CRLF の本文も読む" {
  setup_auto
  fake_issue_body 17 $'### TASKS\r\n- [x] done\r\n\r\n### Acceptance Criteria ###\r\n1. works\r\n'
  run_check --issue 17
  assert_equal "$(jq -r .action <<<"$output")" proceed
}

@test "PR の番号なら止まる" {
  setup_auto
  jq '.url = "https://github.com/me/demo/pull/17"' "$FIX/issue-17.json" >"$TMP/i.json" && mv "$TMP/i.json" "$FIX/issue-17.json"
  run_check --issue 17
  assert_failure 2
  assert_output --partial "#17 は PR です"
}

@test "type ラベルは大文字と小文字を区別せずに照合し、設定の書き方の type にする（Fix と fix は1つと数える）" {
  setup_auto
  for labels in '["Fix"]' '["Fix", "fix"]'; do
    fake_issue 17 "$labels"
    fake_issue_body 17 "$BODY"
    run_check --issue 17
    assert_success
    assert_equal "$(jq -c '[.action, .issue.type]' <<<"$output")" '["proceed","fix"]'
  done
}

@test "本文の節は md_scan と同じ決まりで読む（コードブロックの閉じ方・行内の \`\`\`・行の途中の <!--・節の中の小見出し）" {
  setup_auto
  # ```` の囲みの中の ``` では閉じない。```x``` は囲みではない。行の途中の <!-- はコメントの始まりではない。
  # 節の中の ### の小見出しの下の項目も、その節の項目として数える
  fake_issue_body 17 '## やること
````
```
## 完了条件
````
```bash run.sh```
### スクリプト
- [ ] a.sh を足す <!-- 補足

## 完了条件
- a.sh が動く'
  run_check --issue 17
  assert_success
  assert_equal "$(jq -c '[.action, .reasons]' <<<"$output")" '["proceed",[]]'
}

@test "小見出しの節は、同じかより上の段の見出しで終わる（別の節の項目を数えない）" {
  setup_auto
  fake_issue_body 17 '### やること
## 背景
- 項目に見えるが背景の行
## 完了条件
- a.sh が動く'
  run_check --issue 17
  assert_equal "$(jq -c .reasons <<<"$output")" '["本文の「やること」に項目がありません（何をするかが決まっていません）"]'
}

@test "無効なら、auto の値が誤っていても disabled を返す（Issue も読まない）" {
  setup_fake_gh
  set_config '. + {auto: {enabled: false, max_fix_attempts: 0, max_new_issues: "x"}}'
  run_check --issue 17
  assert_success
  assert_equal "$(jq -c '[.action, .settings]' <<<"$output")" '["disabled",null]'
  assert_equal "$(called issue-view)" 0
}

@test "閉じた Issue は、止まる条件（breaking・type ラベル・本文）にも当たっても not_startable（hold にしない）" {
  setup_auto
  fake_issue 17 '["feat", "breaking"]' CLOSED
  run_check --issue 17
  assert_success
  assert_equal "$(jq -c '[.action, .reasons]' <<<"$output")" '["not_startable",["Issue #17 は閉じています"]]'
}

@test "issue に本文（body）も出す（task-auto が Issue を読み直さずに、あいまいかを判断できるように）" {
  setup_auto
  run_check --issue 17
  assert_equal "$(jq -r .issue.body <<<"$output")" "$BODY"
}
