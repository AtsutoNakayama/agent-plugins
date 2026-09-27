#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper
load fake_gh

# origin 役の bare リポジトリに main を push し、作業用のブランチ feat/17-x に1つコミットしておく
setup_branch() {
  setup_fake_gh
  git add .claude/workflow.json
  git commit -q -m config
  git init -q --bare -b main "$TMP/origin.git"
  git remote add origin "$TMP/origin.git"
  git push -q origin main
  git checkout -q -b feat/17-x
  echo work >work.txt
  git add work.txt
  git commit -q -m "feat: work"
  printf '## 概要\n作業した\n\n## 変更点\n- work.txt\n\n## 確認方法\n- 見た\n\nCloses #\n' >"$TMP/body.md"
}

run_pr() {
  run_script pr-create.sh "$@"
  printf '%s\n' "$output"
  json="$(json_of "$output")"
}

@test "push して、Issue のタイトルとラベルで PR を作る" {
  setup_branch
  fake_issue 17 '["feat", "priority: high"]'
  run_pr --issue 17 --body-file "$TMP/body.md"
  assert_success
  assert_equal "$(jq -c '[.title, .created, .pr.number, .pr.url, .draft, .status.skipped]' <<<"$json")" \
    '["feat: 作業 17",true,42,"https://github.com/me/demo/pull/42",false,true]'
  assert_equal "$(git rev-parse origin/feat/17-x)" "$(git rev-parse HEAD)"
  assert_equal "$(git rev-parse --abbrev-ref '@{upstream}')" origin/feat/17-x
  run args pr-create
  assert_output --partial "--base main --head feat/17-x --title feat: 作業 17 --body-file "
  assert_output --partial "--label feat --label priority: high"
  refute_output --partial --draft
}

@test "本文の空の Closes # の行を消し、Closes #N を末尾に足す" {
  setup_branch
  run_pr --issue 17 --body-file "$TMP/body.md"
  assert_success
  assert_equal "$(cat "$TMP/pr-body")" "$(printf '## 概要\n作業した\n\n## 変更点\n- work.txt\n\n## 確認方法\n- 見た\n\nCloses #17')"
  assert_equal "$(jq -r .body <<<"$json")" "$(cat "$TMP/pr-body")"
}

@test "本文に Closes #N があれば足さない（#170 は別の Issue とみなす）" {
  setup_branch
  printf '概要\n\ncloses #17\n' >"$TMP/b1.md"
  run_pr --issue 17 --body-file "$TMP/b1.md" --dry-run
  assert_equal "$(jq -r .body <<<"$json")" "$(printf '概要\n\ncloses #17')"
  printf '概要\n\nCloses #170\n' >"$TMP/b2.md"
  run_pr --issue 17 --body-file "$TMP/b2.md" --dry-run
  assert_equal "$(jq -r .body <<<"$json")" "$(printf '概要\n\nCloses #170\n\nCloses #17')"
}

@test "本文が空ならエラーになる" {
  setup_branch
  printf 'Closes #\n' >"$TMP/empty.md"
  run_pr --issue 17 --body-file "$TMP/empty.md"
  assert_failure 64
  assert_output --partial "本文が空です"
}

@test "--title で指定したタイトルを使う" {
  setup_branch
  run_pr --issue 17 --body-file "$TMP/body.md" --title "feat(pr): 別のタイトル"
  assert_success
  assert_equal "$(jq -r .title <<<"$json")" "feat(pr): 別のタイトル"
}

@test "タイトルが規約に合わなければ、push せずに止まる" {
  setup_branch
  run_pr --issue 17 --body-file "$TMP/body.md" --title "作業 17"
  assert_failure 2
  assert_output --partial "タイトルが規約に合いません"
  run git rev-parse -q --verify origin/feat/17-x
  assert_failure
}

@test "タイトルの type が Issue の type ラベルと違えば止まる" {
  setup_branch
  run_pr --issue 17 --body-file "$TMP/body.md" --title "fix: 作業 17"
  assert_failure 2
  assert_output --partial "タイトルの type（fix）が Issue #17 の type ラベル（feat）と違います"
}

@test "Issue に type ラベルが無ければ止まる" {
  setup_branch
  fake_issue 17 '[]'
  run_pr --issue 17 --body-file "$TMP/body.md"
  assert_failure 2
  assert_output --partial "Issue #17 の type ラベルを1つにしてください（今は なし）"
}

@test "pr.draft が true なら下書きにする" {
  setup_branch
  jq '. + {pr: {draft: true}}' .claude/workflow.json >"$TMP/c.json" && mv "$TMP/c.json" .claude/workflow.json
  git commit -q -am "chore: draft"
  run_pr --issue 17 --body-file "$TMP/body.md"
  assert_success
  assert_equal "$(jq .draft <<<"$json")" true
  run args pr-create
  assert_output --partial --draft
}

# status.pr_opened を Done にする
set_pr_opened() {
  jq '. + {status: {pr_opened: "Done"}}' .claude/workflow.json >"$TMP/c.json" && mv "$TMP/c.json" .claude/workflow.json
  git commit -q -am "chore: status"
}

@test "開いた PR が既にあれば、push だけして作り直さず、タイトル・本文・列も変えない" {
  setup_branch
  set_pr_opened
  echo '[{"number": 7, "url": "https://github.com/me/demo/pull/7", "isCrossRepository": false}]' >"$FIX/pr-list.json"
  run_pr --issue 17 --body-file "$TMP/body.md"
  assert_success
  assert_equal "$(jq -c '[.created, .pr.number, .title, .body, .labels, .status.skipped]' <<<"$json")" '[false,7,null,null,null,true]'
  assert_equal "$(called pr-create)" 0
  assert_equal "$(called SetField)" 0
  assert_equal "$(git rev-parse origin/feat/17-x)" "$(git rev-parse HEAD)"
  assert_equal "$(args pr-list)" "--head feat/17-x --state open --json number,url,isCrossRepository"
}

@test "fork の同じ名前のブランチからの PR は、既にある PR とみなさない" {
  setup_branch
  echo '[{"number": 7, "url": "https://github.com/me/demo/pull/7", "isCrossRepository": true}]' >"$FIX/pr-list.json"
  run_pr --issue 17 --body-file "$TMP/body.md"
  assert_success
  assert_equal "$(jq -c '[.created, .pr.number]' <<<"$json")" '[true,42]'
}

@test "status.pr_opened が設定されていれば、その列に移す" {
  setup_branch
  set_pr_opened
  run_pr --issue 17 --body-file "$TMP/body.md"
  assert_success
  assert_equal "$(jq -c '[.status.from, .status.to]' <<<"$json")" '["Todo","Done"]'
  assert_equal "$(args SetField | jq -r .v.singleSelectOptionId)" O3
}

@test "PR を作った後に列を移せなければ、移し方を伝えて止まる" {
  setup_branch
  set_pr_opened
  FAKE_FAIL=SetField run_pr --issue 17 --body-file "$TMP/body.md"
  assert_failure 1
  assert_output --partial "PR #42 は作りましたが、Issue #17 の列を移せませんでした（status-set.sh --issue 17 --to pr_opened で移せます）"
}

@test "dry-run で列の移動の予定を作れなければ、PR を作ったとは言わずに止まる" {
  setup_branch
  set_pr_opened
  FAKE_FAIL=ProjectFields run_pr --issue 17 --body-file "$TMP/body.md" --dry-run
  assert_failure 1
  assert_output --partial "Issue #17 を列に移す予定を作れませんでした"
  refute_output --partial "作りましたが"
}

@test "status.pr_opened が既定（null）なら、列を移さない" {
  setup_branch
  run_pr --issue 17 --body-file "$TMP/body.md"
  assert_success
  assert_equal "$(called ProjectFields)" 0
}

@test "dry-run では push も PR の作成もせず、予定を出す" {
  setup_branch
  run_pr --issue 17 --body-file "$TMP/body.md" --dry-run
  assert_success
  run git rev-parse -q --verify origin/feat/17-x
  assert_failure
  assert_equal "$(called pr-create)" 0
  assert_equal "$(jq -c '[.dry_run, .pr, .actions]' <<<"$json")" \
    '[true,null,["feat/17-x を origin に push する（origin/main より 1 個先のコミット）","main に向けた PR「feat: 作業 17」を作る","PR にラベル feat を付ける"]]'
}

@test "未コミットの変更があれば止まる" {
  setup_branch
  echo more >>work.txt
  run_pr --issue 17 --body-file "$TMP/body.md"
  assert_failure 2
  assert_output --partial "未コミットの変更があります"
}

@test "origin/main より先のコミットが無ければ止まる" {
  setup_branch
  git checkout -q -b feat/17-empty main
  run_pr --issue 17 --body-file "$TMP/body.md"
  assert_failure 2
  assert_output --partial "origin/main に無いコミットがありません"
}

@test "main の上では止まる" {
  setup_branch
  git checkout -q main
  run_pr --issue 17 --body-file "$TMP/body.md"
  assert_failure 2
  assert_output --partial "main からは PR を作りません"
}

@test "push できなければ、PR を作らずに止まる" {
  setup_branch
  git push -q origin feat/17-x
  git reset -q --hard HEAD~1
  echo other >other.txt
  git add other.txt
  git commit -q -m "feat: other"
  run_pr --issue 17 --body-file "$TMP/body.md"
  assert_failure 1
  assert_output --partial "feat/17-x を push できませんでした"
  assert_equal "$(called pr-create)" 0
}

@test "PR を作れなければ、push したことを伝えて止まる" {
  setup_branch
  FAKE_FAIL=pr-create run_pr --issue 17 --body-file "$TMP/body.md"
  assert_failure 1
  assert_output --partial "feat/17-x は push しましたが、PR を作れませんでした"
}

@test "本文は標準入力からも読める" {
  setup_branch
  run_script pr-create.sh --issue 17 --body-file - --dry-run <"$TMP/body.md"
  assert_success
  json="$(json_of "$output")"
  assert_equal "$(jq -r .body <<<"$json" | tail -n 1)" "Closes #17"
}
