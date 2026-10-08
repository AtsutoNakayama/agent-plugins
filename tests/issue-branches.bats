#!/usr/bin/env bats
# Issue の作業のブランチと、Issue を閉じる開いている PR を探す（issue-branches.sh）。
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper
load fake_gh

setup() {
  test_helper_setup
  setup_fake_gh
  git init -q --bare -b main "$TMP/origin.git"
  git remote add origin "$TMP/origin.git"
  git push -q origin main
  link_prs
}

run_branches() {
  run_script issue-branches.sh "$@"
  printf '%s\n' "$output"
  json="$(json_of "$output")"
}

# 使い方: names <branches か candidates> → [名前, 手元にあるか, origin にあるか] の一覧
names() { jq -c --arg k "${1:-branches}" '[.[$k][] | [.name, .local, .remote]]' <<<"$json"; }

@test "branch.pattern に合い番号が一致する手元と origin のブランチを、確かなブランチとして出す（ほかの Issue のブランチは入れない）" {
  git branch feat/17-x
  git branch fix/170-y
  git branch fix/1-7-segment
  git push -q origin main:refs/heads/docs/17-z
  run_branches --issue 17
  assert_success
  assert_equal "$(names)" '[["docs/17-z",false,true],["feat/17-x",true,false]]'
  assert_equal "$(jq -c '[.candidates, .open_prs]' <<<"$json")" '[[],[]]'
}

@test "branch.pattern に合わない名前は候補に出し、確かなブランチにはしない（先頭に 0 が付いた古い名前は確か）" {
  for b in wip/17-try feat/17-Fix_Login feat/017-old 17-bare; do git branch "$b"; done
  run_branches --issue 17
  assert_success
  assert_equal "$(jq -c '[.branches[].name]' <<<"$json")" '["feat/017-old"]'
  assert_equal "$(jq -c '[.candidates[] | [.name, .from]]' <<<"$json")" \
    '[["17-bare","name"],["feat/17-Fix_Login","name"],["wip/17-try","name"]]'
}

@test "名前が似ているだけの関係の無いブランチ（日付・版の番号）は、確かなブランチにしない（消さないため）" {
  fake_issue 2024 '["feat"]'
  fake_issue 1 '["feat"]'
  git branch backup/2024-01-15
  git branch release/1-0-x
  run_branches --issue 2024
  assert_success
  assert_equal "$(jq -c '[[.branches[].name], [.candidates[].name]]' <<<"$json")" '[[],["backup/2024-01-15"]]'
  run_branches --issue 1
  assert_success
  assert_equal "$(jq -c '[[.branches[].name], [.candidates[].name]]' <<<"$json")" '[[],["release/1-0-x"]]'
}

@test "設定で branch.pattern の形を変えても、その形で確かなブランチを見つける" {
  jq '. + {branch: {pattern: "{type}-{issue_number}-{slug}"}}' .claude/dev-workflow/config.json >"$TMP/c" \
    && mv "$TMP/c" .claude/dev-workflow/config.json
  git branch feat-17-login
  git branch feat/17-x
  run_branches --issue 17
  assert_success
  assert_equal "$(jq -c '[[.branches[].name], [.candidates[].name]]' <<<"$json")" '[["feat-17-login"],["feat/17-x"]]'
}

@test "タグと同じ名前のブランチも、手元のブランチとして見つける" {
  git branch feat/17-x
  git tag feat/17-x
  run_branches --issue 17
  assert_success
  assert_equal "$(names)" '[["feat/17-x",true,false]]'
}

@test "句読点だけが違う名前を、ロケールによらず別のブランチとして扱う" {
  # C 以外の UTF-8 のロケールでは、sort -u が句読点を無視して、別の名前を同じとみなすことがある（uutils の sort など）
  loc="$(locale -a 2>/dev/null | grep -Ei '^[a-z]{2}_[A-Z]{2}\.utf-?8$' | head -n 1 || true)"
  [ -n "$loc" ] || skip "C 以外の UTF-8 のロケールが無い"
  fake_issue 1 '["feat"]'
  git branch feat/1-7-segment-display
  git branch feat/17-segment-display
  LC_ALL="$loc" LANG="$loc" run_branches --issue 17
  assert_success
  assert_equal "$(jq -c '[.branches[].name]' <<<"$json")" '["feat/17-segment-display"]'
  LC_ALL="$loc" LANG="$loc" run_branches --issue 1
  assert_success
  assert_equal "$(jq -c '[.branches[].name]' <<<"$json")" '["feat/1-7-segment-display"]'
}

@test "origin のブランチが多くても（名前の合計が引数の長さの上限の 128 KiB を超えても）止まらない" {
  sha="$(git rev-parse HEAD)"
  {
    echo '# pack-refs with: peeled fully-peeled sorted'
    printf '%s refs/heads/feat/17-x\n' "$sha"
    for i in $(seq 1 2500); do
      printf '%s refs/heads/renovate/some-very-long-package-scope-name-and-version-%04d.x-lockfile\n' "$sha" "$i"
    done
  } >"$TMP/origin.git/packed-refs"
  run_branches --issue 17
  assert_success
  assert_equal "$(names)" '[["feat/17-x",false,true]]'
}

@test "ワークツリーで使っているブランチには、その場所を付ける（手で消したディレクトリの記録は付けない）" {
  git worktree add -q -b feat/17-x "$TMP/wt"
  run_branches --issue '#17'
  assert_success
  assert_equal "$(jq -r '.branches[0].worktree' <<<"$json")" "$TMP/wt"
  rm -rf "$TMP/wt"
  run_branches --issue 17
  assert_success
  assert_equal "$(jq -c '.branches[0].worktree' <<<"$json")" null
}

@test "Issue を閉じる PR のブランチは、手元か origin に残っていれば候補にだけ出し（今のリポジトリのもの）、開いているものは open_prs にも出す" {
  git branch fix-foo
  link_prs 5:OPEN:fix-foo 6:MERGED:old-work 7:OPEN:patch-1:other/lib 8:CLOSED:gave-up 9:OPEN:patch-2:me/demo:true
  run_branches --issue 17
  assert_success
  assert_equal "$(jq -c .branches <<<"$json")" '[]'
  # old-work は手元にも origin にも無い（片付け終えた）ので、候補に出さない
  assert_equal "$(jq -c '[.candidates[] | [.name, .local, .from, .pr]]' <<<"$json")" '[["fix-foo",true,"pr",5]]'
  assert_equal "$(jq -c '[.open_prs[] | [.number, .branch]]' <<<"$json")" '[[5,"fix-foo"],[7,"patch-1"],[9,"patch-2"]]'
}

@test "open_prs の cross は、別のリポジトリかフォークの PR なら true にし、merged_prs には今のリポジトリのマージ済みの PR だけを出す" {
  link_prs 5:OPEN:a 6:MERGED:b 7:OPEN:c:other/lib 8:MERGED:d:other/lib 9:OPEN:e:me/demo:true 10:MERGED:f:me/demo:true \
    11:OPEN:g:none 12:MERGED:h:none
  run_branches --issue 17
  assert_success
  assert_equal "$(jq -c '[.open_prs[] | [.number, .cross]]' <<<"$json")" '[[5,false],[7,true],[9,true],[11,false]]'
  assert_equal "$(jq -c '[.merged_prs[] | [.number, .branch]]' <<<"$json")" '[[6,"b"],[12,"h"]]'
}

@test "Closes #17, #18 の PR のブランチ（別の Issue の作業）を、#17 の確かなブランチにしない" {
  git worktree add -q -b feat/18-x "$TMP/wt18"
  link_prs 5:OPEN:feat/18-x
  run_branches --issue 17
  assert_success
  assert_equal "$(jq -c .branches <<<"$json")" '[]'
  assert_equal "$(jq -c '[.candidates[] | [.name, .from]]' <<<"$json")" '[["feat/18-x","pr"]]'
}

@test "Issue の番号・タイトル・状態と、開いている子の数を出す" {
  jq '. + {subIssuesSummary: {total: 3, completed: 1, percentCompleted: 33}}' "$FIX/issue-17.json" >"$FIX/i" \
    && mv "$FIX/i" "$FIX/issue-17.json"
  run_branches --issue 17
  assert_success
  assert_equal "$(jq -c '.issue | [.number, .title, .state, .open_sub_issues]' <<<"$json")" '[17,"作業 17","OPEN",2]'
}

@test "origin を読めなければ、「origin に無い」と区別できないまま出さずに止まる" {
  git branch feat/17-x
  git remote set-url origin "$TMP/no-such.git"
  run_branches --issue 17
  assert_failure 1
  assert_output "error: origin のブランチを読めませんでした（通信や認証を確かめてください）"
}

@test "Issue を閉じる PR を読めなければ、開いている PR が無いと決めつけずに止まる" {
  link_prs 5:OPEN:fix-foo
  FAKE_FAIL=pr-view run_branches --issue 17
  assert_failure 1
  assert_output --partial "PR https://github.com/me/demo/pull/5 を読めませんでした"
}

@test "gh が古ければ（Issue を閉じる PR を読めない）、更新を促して止まる" {
  FAKE_GH_VERSION=2.72.0 run_branches --issue 17
  assert_failure 2
  assert_output --partial "gh 2.88.0 以上が要ります（今は 2.72.0）"
}

@test "Issue を読めなければ止まる。--issue が数字でなければ使い方の誤り" {
  FAKE_FAIL=issue-view run_branches --issue 17
  assert_failure 1
  assert_output --partial "Issue #17 を読めません: gh: failed"
  run_branches --issue x
  assert_failure 64
}

@test "先頭に 0 が付いた --issue（017）でも、名前のブランチ（feat/17-x）を見つける" {
  git branch feat/17-x
  run_branches --issue 017
  assert_success
  assert_equal "$(jq -c '[.issue.number, [.branches[].name]]' <<<"$json")" '[17,["feat/17-x"]]'
}

@test "PR の番号は Issue として受け取らずに止まる（task-finish が PR を Issue として閉じないため）" {
  echo '{"url": "https://github.com/me/demo/pull/21", "number": 21, "closedByPullRequestsReferences": []}' >"$FIX/issue-21.json"
  run_branches --issue 21
  assert_failure 2
  assert_output --partial "#21 は PR です。Issue の番号を指定してください"
}

@test "Issue を閉じる PR のブランチが、名前で見つかったブランチと同じなら、二重に出さない" {
  git branch feat/17-x
  git branch wip/17-try
  link_prs 5:OPEN:feat/17-x 6:MERGED:wip/17-try
  run_branches --issue 17
  assert_success
  assert_equal "$(jq -c '[[.branches[].name], [.candidates[] | [.name, .from]]]' <<<"$json")" '[["feat/17-x"],[["wip/17-try","name"]]]'
}

@test "Issue を閉じる PR のブランチが origin にだけ残っていても、候補に出す" {
  git push -q origin main:refs/heads/old-work
  link_prs 6:MERGED:old-work 7:MERGED:gone-work
  run_branches --issue 17
  assert_success
  assert_equal "$(jq -c '[.candidates[] | [.name, .local, .remote, .from, .pr]]' <<<"$json")" '[["old-work",false,true,"pr",6]]'
}

# 使い方: action_of <状態（OPEN・CLOSED）> <開いている子の数> → $FIX/issue-17.json の状態と子の数を変えて実行し、action を返す
action_of() {
  jq --arg s "$1" --argjson n "$2" '. + {state: $s, subIssuesSummary: {total: $n, completed: 0, percentCompleted: 0}}' \
    "$FIX/issue-17.json" >"$FIX/i" && mv "$FIX/i" "$FIX/issue-17.json"
  run_branches --issue 17 >/dev/null
  assert_success
  jq -r .action <<<"$json"
}

@test "task-finish がすることを action に出す（確かなブランチ・Issue の状態・開いている PR・開いている子・候補の組み合わせ）" {
  # どれも無い：開いている Issue なら閉じるかを聞き、閉じていれば何もしない
  assert_equal "$(action_of OPEN 0)" ask_close
  assert_equal "$(action_of CLOSED 0)" nothing
  # 開いている子だけ：閉じない（親は最後の子を閉じた後に人が閉じる）
  assert_equal "$(action_of OPEN 2)" blocked_sub_issues
  # Issue を閉じる PR が開いている（フォークの PR。手元に片付けるブランチは無い）：開いている子より先に見る。閉じていれば何もしない
  link_prs 5:OPEN:patch-1:me/demo:true
  assert_equal "$(action_of OPEN 2)" blocked_open_pr
  assert_equal "$(action_of OPEN 0)" blocked_open_pr
  assert_equal "$(action_of CLOSED 0)" nothing
  # 候補がある：開いている Issue なら閉じるかを聞き（候補は質問の中で見せる）、閉じていれば候補で片付けるかを聞く
  link_prs
  git branch wip/17-try
  assert_equal "$(action_of OPEN 0)" ask_close
  assert_equal "$(action_of CLOSED 0)" cleanup_candidate
  # 確かなブランチがある：ほかの値によらず片付ける（開いている PR は cleanup.sh が止める）
  git branch feat/17-x
  link_prs 5:OPEN:patch-1:me/demo:true
  assert_equal "$(action_of OPEN 2)" cleanup
  assert_equal "$(action_of CLOSED 0)" cleanup
}
