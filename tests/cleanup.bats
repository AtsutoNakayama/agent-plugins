#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper
load fake_gh

WT_REL=.claude/worktrees/feat/17-x

# origin 役の bare リポジトリに main を push し、feat/17-x のワークツリーで1つコミットして push しておく
setup_branch() {
  setup_fake_gh
  git add .claude/workflow.json
  git commit -q -m config
  git init -q --bare -b main "$TMP/origin.git"
  git remote add origin "$TMP/origin.git"
  git push -q origin main
  echo '.claude/worktrees/' >>.git/info/exclude

  WT="$REPO/$WT_REL"
  git worktree add -q -b feat/17-x "$WT" main
  echo work >"$WT/work.txt"
  git -C "$WT" add work.txt
  git -C "$WT" commit -q -m "feat: work"
  git -C "$WT" push -q origin feat/17-x
}

# origin の main にスカッシュマージしたことにする（手元の main は1つ遅れたまま）
squash_merge() {
  git merge -q --squash feat/17-x
  git commit -q -m "feat: 作業 17 (#5)"
  git push -q origin main
  git reset -q --hard HEAD~1
  git push -q origin --delete feat/17-x
}

# 使い方: fake_pr <状態> [PR の最後のコミット（既定: feat/17-x の今のコミット）]
fake_pr() {
  jq -n --arg s "$1" --arg oid "${2:-$(git rev-parse feat/17-x)}" '[{number: 5, url: "https://github.com/me/demo/pull/5",
    state: $s, mergedAt: (if $s == "MERGED" then "2026-09-27T00:00:00Z" else null end), headRefOid: $oid, baseRefName: "main"}]' \
    >"$FIX/pr-list.json"
}

run_cleanup() {
  run_script cleanup.sh "$@"
  printf '%s\n' "$output"
  json="$(json_of "$output")"
}

@test "マージを確かめ、ワークツリーとブランチを削除し、main を最新にする" {
  setup_branch
  squash_merge
  fake_pr MERGED
  before="$(git rev-parse main)"
  run_cleanup --branch feat/17-x
  assert_success
  [ ! -e "$WT" ]
  run git show-ref --verify --quiet refs/heads/feat/17-x
  assert_failure
  assert_equal "$(git rev-parse main)" "$(git rev-parse origin/main)"
  assert_equal "$(jq -c '[.pr.number, .worktree, .removed.worktree, .removed.branch, .switched]' <<<"$json")" \
    "[5,\"$WT\",true,true,false]"
  assert_equal "$(jq -c '[.base.from, .base.to]' <<<"$json")" "[\"$before\",\"$(git rev-parse origin/main)\"]"
  # 削除された origin/feat/17-x の追跡ブランチも片付ける
  run git show-ref --verify --quiet refs/remotes/origin/feat/17-x
  assert_failure
  assert_equal "$(args pr-list)" "--head feat/17-x --state all --json number,url,state,mergedAt,headRefOid,baseRefName"
}

@test "--branch を省略すると、今のブランチを片付ける（ワークツリーの中から実行できる）" {
  setup_branch
  squash_merge
  fake_pr MERGED
  cd "$WT"
  run_cleanup
  assert_success
  assert_equal "$(jq -r .branch <<<"$json")" feat/17-x
  assert_equal "$(jq -r .main_root <<<"$json")" "$REPO"
  [ ! -e "$WT" ]
}

@test "dry-run では何も変えず、予定だけを出す" {
  setup_branch
  squash_merge
  fake_pr MERGED
  before="$(git rev-parse main)"
  run_cleanup --branch feat/17-x --dry-run
  assert_success
  [ -d "$WT" ]
  git show-ref --verify --quiet refs/heads/feat/17-x
  assert_equal "$(git rev-parse main)" "$before"
  assert_equal "$(jq -c '.actions' <<<"$json")" \
    "[\"ワークツリー $WT を削除する\",\"ローカルのブランチ feat/17-x を削除する\",\"$REPO の main に origin/main を早送りで取り込む（git pull --ff-only）\"]"
}

@test "2回目は既に無いワークツリーとブランチを飛ばし、main だけ最新にする" {
  setup_branch
  squash_merge
  fake_pr MERGED
  run_cleanup --branch feat/17-x
  run_cleanup --branch feat/17-x
  assert_success
  assert_equal "$(jq -c '[.worktree, .removed.worktree, .removed.branch]' <<<"$json")" '[null,false,false]'
}

@test "PR がまだマージされていなければ止まる" {
  setup_branch
  fake_pr OPEN
  run_cleanup --branch feat/17-x
  assert_failure 2
  assert_output --partial "PR #5 はまだマージされていません"
  [ -d "$WT" ]
}

@test "PR が無ければ止まる" {
  setup_branch
  run_cleanup --branch feat/17-x
  assert_failure 2
  assert_output --partial "feat/17-x のマージされた PR がありません"
}

@test "PR に入っていないコミットがあれば止まる" {
  setup_branch
  squash_merge
  fake_pr MERGED
  echo more >"$WT/more.txt"
  git -C "$WT" add more.txt
  git -C "$WT" commit -q -m "feat: more"
  run_cleanup --branch feat/17-x
  assert_failure 2
  assert_output --partial "feat/17-x に PR #5 に入っていないコミットがあります"
  [ -d "$WT" ]
}

@test "手元のブランチが PR の最後のコミットより古いだけなら片付ける" {
  setup_branch
  git -C "$WT" commit -q --allow-empty -m "feat: pushed from elsewhere"
  head="$(git rev-parse feat/17-x)"
  git -C "$WT" reset -q --hard HEAD~1
  squash_merge
  fake_pr MERGED "$head"
  run_cleanup --branch feat/17-x
  assert_success
  [ ! -e "$WT" ]
}

@test "ワークツリーに未コミットの変更があれば止まる" {
  setup_branch
  squash_merge
  fake_pr MERGED
  echo dirty >"$WT/dirty.txt"
  run_cleanup --branch feat/17-x
  assert_failure 2
  assert_output --partial "$WT に未コミットの変更があります"
  [ -f "$WT/dirty.txt" ]
  git show-ref --verify --quiet refs/heads/feat/17-x
}

@test "メインのワークツリーでブランチを使っていたら、main に切り替えてから削除する" {
  setup_branch
  git worktree remove "$WT"
  squash_merge
  git switch -q feat/17-x
  fake_pr MERGED
  run_cleanup --branch feat/17-x
  assert_success
  assert_equal "$(git symbolic-ref --short HEAD)" main
  assert_equal "$(git rev-parse main)" "$(git rev-parse origin/main)"
  assert_equal "$(jq -c '[.switched, .removed.worktree, .removed.branch]' <<<"$json")" '[true,false,true]'
}

@test "main をどのワークツリーでも使っていなければ、ref だけ早送りする" {
  setup_branch
  squash_merge
  git switch -q --detach
  fake_pr MERGED
  run_cleanup --branch feat/17-x
  assert_success
  assert_equal "$(git rev-parse main)" "$(git rev-parse origin/main)"
  assert_equal "$(jq -r '.actions[-1]' <<<"$json")" "main を origin/main まで早送りする"
}

@test "main に origin に無いコミットがあれば、早送りできずに止まる" {
  setup_branch
  squash_merge
  git commit -q --allow-empty -m "local only"
  fake_pr MERGED
  run_cleanup --branch feat/17-x
  assert_failure 1
  assert_output --partial "main を早送りで最新にできません"
}

@test "ワークツリーのディレクトリが手で消されていたら、記録を片付ける" {
  setup_branch
  squash_merge
  fake_pr MERGED
  rm -rf "$WT"
  run_cleanup --branch feat/17-x
  assert_success
  assert_equal "$(jq -r '.actions[0]' <<<"$json")" "消えたワークツリー $WT の記録を片付ける（git worktree prune）"
  assert_equal "$(git worktree list --porcelain | grep -c '^worktree ')" 1
}

@test "main は片付けられない" {
  setup_branch
  run_cleanup --branch main
  assert_failure 64
  assert_output --partial "main は片付けられません"
  git switch -q main
  run_cleanup
  assert_failure 64
}
