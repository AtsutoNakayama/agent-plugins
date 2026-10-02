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

# サブモジュール lib/sub（$TMP/sub）を main にコミットしておく。setup_branch より前に呼ぶ
add_submodule() {
  # 手元のパスのサブモジュールは、git の既定では取得を禁止されている（CVE-2022-39253）ので、テストの中だけ許す
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
  git init -q -b main "$TMP/sub"
  echo sub >"$TMP/sub/README"
  git -C "$TMP/sub" add README
  git -C "$TMP/sub" commit -q -m sub
  git submodule add -q "$TMP/sub" lib/sub
  git commit -q -m submodule
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

@test "ワークツリーに git が無視するファイルがあれば、何も消さずに止まる" {
  setup_branch
  squash_merge
  fake_pr MERGED
  printf '%s\n' .env 'build/' >>.git/info/exclude
  echo SECRET=1 >"$WT/.env"
  mkdir "$WT/build"
  echo out >"$WT/build/out.txt"
  run_cleanup --branch feat/17-x
  assert_failure 2
  assert_output --partial "$WT に git が無視するファイル（.env, build/）があります"
  assert_output --partial "--remove-ignored"
  [ -f "$WT/.env" ]
  git show-ref --verify --quiet refs/heads/feat/17-x
}

@test "git が無視するファイルが6つ以上あれば、5つまで出して残りの数を添える" {
  setup_branch
  squash_merge
  fake_pr MERGED
  echo '*.log' >>.git/info/exclude
  for i in 1 2 3 4 5 6 7; do echo x >"$WT/$i.log"; done
  run_cleanup --branch feat/17-x
  assert_failure 2
  assert_output --partial "（1.log, 2.log, 3.log, 4.log, 5.log ほか 2 件）"
}

@test "--remove-ignored を付ければ、git が無視するファイルごと削除する" {
  setup_branch
  squash_merge
  fake_pr MERGED
  echo .env >>.git/info/exclude
  echo SECRET=1 >"$WT/.env"
  run_cleanup --branch feat/17-x --remove-ignored
  assert_success
  [ ! -e "$WT" ]
  run git show-ref --verify --quiet refs/heads/feat/17-x
  assert_failure
}

@test "status.showUntrackedFiles=no でも、追跡していないファイルや git が無視するファイルがあれば止まる" {
  setup_branch
  squash_merge
  fake_pr MERGED
  git config status.showUntrackedFiles no
  echo new >"$WT/new.txt"
  run_cleanup --branch feat/17-x
  assert_failure 2
  assert_output --partial "$WT に未コミットの変更があります"
  rm "$WT/new.txt"
  echo .env >>.git/info/exclude
  echo SECRET=1 >"$WT/.env"
  run_cleanup --branch feat/17-x
  assert_failure 2
  assert_output --partial "$WT に git が無視するファイル（.env）があります"
  [ -f "$WT/.env" ]
}

@test "status.showUntrackedFiles=no でも、サブモジュールの中の git が無視するファイルがあれば止まる" {
  add_submodule
  setup_branch
  git -C "$WT" submodule update -q --init
  squash_merge
  fake_pr MERGED
  # サブモジュールの中にも効くよう、環境変数で設定する（add_submodule が GIT_CONFIG_KEY_0 を使っている）
  export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_1=status.showUntrackedFiles GIT_CONFIG_VALUE_1=no
  echo .env >>"$(git -C "$WT/lib/sub" rev-parse --git-path info/exclude)"
  echo SECRET=1 >"$WT/lib/sub/.env"
  run_cleanup --branch feat/17-x
  assert_failure 2
  assert_output --partial "$WT に git が無視するファイル（lib/sub/.env）があります"
}

@test "サブモジュールを初期化したワークツリーも削除する" {
  add_submodule
  setup_branch
  git -C "$WT" submodule update -q --init
  squash_merge
  fake_pr MERGED
  run_cleanup --branch feat/17-x
  assert_success
  [ ! -e "$WT" ]
  run git show-ref --verify --quiet refs/heads/feat/17-x
  assert_failure
}

@test "サブモジュールの中に未コミットの変更があれば止まる" {
  add_submodule
  setup_branch
  git -C "$WT" submodule update -q --init
  squash_merge
  fake_pr MERGED
  echo dirty >>"$WT/lib/sub/README"
  # 設定でサブモジュールの変更を隠していても見つける
  git config submodule.lib/sub.ignore all
  run_cleanup --branch feat/17-x
  assert_failure 2
  assert_output --partial "$WT に未コミットの変更があります"
  assert_equal "$(cat "$WT/lib/sub/README")" "$(printf 'sub\ndirty')"
}

@test "サブモジュールの中に追跡していないファイルがあれば止まる" {
  add_submodule
  setup_branch
  git -C "$WT" submodule update -q --init
  squash_merge
  fake_pr MERGED
  echo new >"$WT/lib/sub/new.txt"
  run_cleanup --branch feat/17-x
  assert_failure 2
  assert_output --partial "$WT に未コミットの変更があります"
  [ -f "$WT/lib/sub/new.txt" ]
}

@test "サブモジュールの中に git が無視するファイルがあれば止まる" {
  add_submodule
  setup_branch
  git -C "$WT" submodule update -q --init
  squash_merge
  fake_pr MERGED
  echo .env >>"$(git -C "$WT/lib/sub" rev-parse --git-path info/exclude)"
  echo SECRET=1 >"$WT/lib/sub/.env"
  run_cleanup --branch feat/17-x
  assert_failure 2
  assert_output --partial "$WT に git が無視するファイル（lib/sub/.env）があります"
  [ -f "$WT/lib/sub/.env" ]
}

@test "サブモジュールにリモートに無いコミットがあれば止まる" {
  add_submodule
  setup_branch
  git -C "$WT" submodule update -q --init
  # サブモジュールのコミットを親に記録して親だけ push し、サブモジュールのリモートには push していない
  git -C "$WT/lib/sub" commit -q --allow-empty -m "local only"
  git -C "$WT" add lib/sub
  git -C "$WT" commit -q -m "feat: bump sub"
  git -C "$WT" push -q origin feat/17-x
  squash_merge
  fake_pr MERGED
  run_cleanup --branch feat/17-x
  assert_failure 2
  assert_output --partial "$WT のサブモジュール（lib/sub）に、リモートに無いコミットか stash があります"
  [ -d "$WT" ]
}

@test "サブモジュールがタグからだけ届くコミットを指していても削除する" {
  add_submodule
  setup_branch
  git -C "$WT" submodule update -q --init
  # サブモジュールのリモートで、どのブランチにも無くタグだけが指すコミットを作る
  git -C "$TMP/sub" commit -q --allow-empty -m tagged
  git -C "$TMP/sub" tag v1
  git -C "$TMP/sub" reset -q --hard HEAD~1
  git -C "$WT/lib/sub" fetch -q --tags origin
  git -C "$WT/lib/sub" switch -q --detach v1
  git -C "$WT" add lib/sub
  git -C "$WT" commit -q -m "feat: sub v1"
  git -C "$WT" push -q origin feat/17-x
  squash_merge
  fake_pr MERGED
  run_cleanup --branch feat/17-x
  assert_success
  [ ! -e "$WT" ]
}

@test "サブモジュールのローカルのブランチにだけリモートに無いコミットがあっても止まる" {
  add_submodule
  setup_branch
  git -C "$WT" submodule update -q --init
  squash_merge
  fake_pr MERGED
  git -C "$WT/lib/sub" switch -q -c wip
  git -C "$WT/lib/sub" commit -q --allow-empty -m "local only"
  git -C "$WT/lib/sub" switch -q --detach HEAD~1
  run_cleanup --branch feat/17-x
  assert_failure 2
  assert_output --partial "$WT のサブモジュール（lib/sub）に、リモートに無いコミットか stash があります"
}

@test "サブモジュールに stash があれば止まる" {
  add_submodule
  setup_branch
  git -C "$WT" submodule update -q --init
  squash_merge
  fake_pr MERGED
  echo dirty >>"$WT/lib/sub/README"
  git -C "$WT/lib/sub" stash -q
  run_cleanup --branch feat/17-x
  assert_failure 2
  assert_output --partial "$WT のサブモジュール（lib/sub）に、リモートに無いコミットか stash があります"
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
