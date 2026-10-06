#!/usr/bin/env bats
# main を守るフック（hooks/guard-git.sh）。
# bats はテストごとにサブシェルで動くので、変数（HOME など）の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper

HOOKS="$BATS_TEST_DIRNAME/../plugins/dev-workflow/hooks"

# フックは導入したリポジトリでだけ動くので、テストのリポジトリを導入したことにする
setup() {
  test_helper_setup
  mark_set_up
}

# フックの入力（JSON）を作って渡す。cwd は既定で今のディレクトリ
# 使い方: run_hook <コマンド> [cwd]
run_hook() {
  jq -n --arg c "$1" --arg d "${2:-$PWD}" '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}, cwd: $d}' \
    >"$TMP/input.json"
  run "${TEST_BASH:-bash}" "$HOOKS/guard-git.sh" <"$TMP/input.json"
}

# 通すコマンド
allowed() {
  local c
  for c in "$@"; do
    run_hook "$c"
    [ "$status" -eq 0 ] || fail "止めてしまった（$status）: $c / $output"
  done
}

# 止めるコマンド。使い方: denied <理由の一部> <コマンド>...
denied() {
  local msg="$1" c
  shift
  for c in "$@"; do
    run_hook "$c"
    [ "$status" -eq 2 ] || fail "止めなかった（$status）: $c"
    assert_output --partial "$msg"
  done
}

# ブランチ名を警告するコマンド。コマンドは止めず、使用者と Claude の両方に警告を伝える
# 使い方: warned <名前> <コマンド>...
warned() {
  local name="$1" c
  shift
  for c in "$@"; do
    run_hook "$c"
    [ "$status" -eq 0 ] || fail "止めてしまった（$status）: $c / $output"
    jq -e . <<<"$output" >/dev/null || fail "JSON を出していない: $c / $output"
    assert_equal "$(jq -r .hookSpecificOutput.hookEventName <<<"$output")" PreToolUse
    assert_equal "$(jq -r .hookSpecificOutput.permissionDecision <<<"$output")" null
    assert_equal "$(jq -r .systemMessage <<<"$output")" "$(jq -r .hookSpecificOutput.additionalContext <<<"$output")"
    [[ "$(jq -r .systemMessage <<<"$output")" == *"ブランチ名 ${name} は規約に合いません"* ]] \
      || fail "警告に名前が無い: $c / $output"
  done
}

# 何も出さずに通すコマンド
silent() {
  local c
  for c in "$@"; do
    run_hook "$c"
    [ "$status" -eq 0 ] || fail "止めてしまった（$status）: $c / $output"
    [ -z "$output" ] || fail "何か出した: $c / $output"
  done
}

@test "hooks.json は Bash の前にフックを呼び、呼ぶスクリプトがある" {
  jq -e '.hooks.PreToolUse[0].matcher == "Bash"' "$HOOKS/hooks.json"
  run jq -r '.hooks.PreToolUse[0].hooks[0].command' "$HOOKS/hooks.json"
  # ${CLAUDE_PLUGIN_ROOT} は Claude Code が置き換える文字なので、そのまま比べる
  # shellcheck disable=SC2016
  assert_output 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/guard-git.sh"'
  [ -f "$HOOKS/guard-git.sh" ]
}

@test "git を使わないコマンドは通す" {
  allowed "ls -la" "echo hello" ""
}

@test "main の上での commit を止める" {
  denied "main の上ではコミットしません" \
    "git commit -m x" \
    "git add a && git commit -m x" \
    "FOO=1 git commit --amend" \
    "git -c user.name=t commit -m x" \
    "git commit -m x 2>&1 | tail -1"
}

@test "作業用のブランチの上の commit は通す" {
  git checkout -q -b feat/21-x
  allowed "git commit -m x" "git commit -m 'fix: main'"
}

@test "main の上でも commit 以外の git の操作は通す" {
  allowed "git status" "git log --oneline -3" "git pull --ff-only" "git fetch origin" "git switch -c feat/21-x"
}

@test "cd や -C で移った先のブランチで判断する" {
  git worktree add -q -b feat/21-x "$TMP/wt"
  allowed "cd $TMP/wt && git commit -m x" "git -C $TMP/wt commit -m x" "cd ../repo/../../${TMP##*/}/wt; git push"
  cd "$TMP/wt"
  denied "main の上ではコミットしません" "cd $REPO && git commit -m x" "git -C $REPO commit -m x" "git -C ../repo commit -m x"
}

@test "base_branch の設定に従う" {
  echo '{"base_branch": "develop"}' >.claude/dev-workflow/config.json
  allowed "git commit -m x" "git push origin HEAD:main"
  git checkout -q -b develop
  denied "develop の上ではコミットしません" "git commit -m x"
  denied "develop へは push しません" "git push"
}

@test "main への push を止める" {
  denied "main へは push しません" \
    "git push" \
    "git push origin" \
    "git push -u origin HEAD" \
    "git push origin main" \
    "git push origin feat/21-x:main" \
    "git push origin HEAD:refs/heads/main" \
    "git push origin --delete main"
  git checkout -q -b feat/21-x
  denied "main へは push しません" "git push origin main" "git push origin HEAD:main" "git push origin -- main"
}

@test "作業用のブランチの push は通す" {
  git checkout -q -b feat/21-x
  allowed "git push" "git push -u origin HEAD" "git push origin feat/21-x" "git push -o ci.skip origin feat/21-x" \
    "git push --force-with-lease" "git push --force-with-lease=feat/21-x origin HEAD" "git push --force-if-includes --force-with-lease"
}

@test "main の上でも、別のブランチを明示した push は通す" {
  allowed "git push origin feat/21-x" "git push origin --delete feat/21-x"
}

@test "強制 push を止める（--force-with-lease は通す）" {
  git checkout -q -b feat/21-x
  denied "強制 push" \
    "git push --force" \
    "git push -f" \
    "git push -uf origin HEAD" \
    "git push origin +feat/21-x" \
    "git push origin +HEAD:feat/21-x" \
    "git push --force-with-lease --force" \
    "git push --mirror"
}

@test "git push の値を取るオプションの値（次の語）を、リモートや refspec と読まない" {
  # main の上で refspec を書かない push。値（check）をリモートと読むと、origin を refspec と読んで通してしまう
  denied "main へは push しません" "git push --recurse-submodules check origin" "git push --recurse-submodules check"
  git checkout -q -b feat/21-x
  denied "main へは push しません" \
    "git push --recurse-submodules check origin main" \
    "git push --recurse-submodules=check origin main" \
    "git push --repo origin origin main" \
    "git push --receive-pack git-receive-pack origin main" \
    "git push --exec git-receive-pack origin main" \
    "git push --push-option x origin main"
  allowed "git push --recurse-submodules check origin feat/21-x"
}

@test "git push の長いオプションを略して書いても、git と同じに読む" {
  git checkout -q -b feat/21-x
  # --mirr・--m は --mirror、--recu は --recurse-submodules（値を取る）
  denied "強制 push" "git push --mirr" "git push --m origin"
  denied "main へは push しません" "git push --recu check origin main" "git push --rep origin origin main" \
    "git push --e git-receive-pack origin main"
  git checkout -q main
  denied "main へは push しません" "git push --recu check origin"
  git checkout -q feat/21-x
  # --force-w は --force-with-lease
  allowed "git push --force-w" "git push --force-with origin feat/21-x"
}

@test "git の値を取るグローバルオプション（--attr-source・--shallow-file）の値を、サブコマンドと読まない" {
  git checkout -q -b feat/21-x
  denied "強制 push" "git --attr-source HEAD push -f" "git --shallow-file x push -f"
}

@test "引用符・ヒアドキュメント・コメントの中の文字は、コマンドとみなさない" {
  git checkout -q -b feat/21-x
  allowed \
    "echo 'git push --force'" \
    "echo \"a; git push -f\"" \
    "git commit -m 'docs: git push -f を止める'" \
    "ls # git push -f" \
    "$(printf 'git commit -F - <<EOF\nfix: x\ngit push --force\nEOF\ngit push')" \
    "$(printf "git commit -m \"\$(cat <<'EOF'\nfix: don't (git push -f)\nEOF\n)\" && git push -u origin HEAD")"
}

@test "if・for・{ }・! の中のコマンドも調べる" {
  denied "強制 push" "if true; then git push --force; fi" "{ git push --force; }" "! git push -f" \
    "while false; do :; done && until true; do git push -f; done"
  denied "main の上ではコミットしません" "for b in a; do git commit -m x; done" "if false; then :; else git commit -m x; fi"
}

@test "( ) の中の cd は、括弧の外に効かない" {
  git worktree add -q -b feat/21-x "$TMP/wt"
  denied "main の上ではコミットしません" "(cd $TMP/wt && git status); git commit -m x" "(cd $TMP/wt) && git commit -m x"
  allowed "(cd $TMP/wt && git commit -m x)" "cd $TMP/wt && (git status) && git commit -m x"
}

@test "パイプラインや & で動かすコマンドは、今は外に効いたものとして読む（{ } の中の cd の後の commit を、その場所で判断する）" {
  git worktree add -q -b feat/21-x "$TMP/wt"
  # { } の中の cd を、コマンドごとに戻して読む誤り（パイプラインを扱いかけたときの退行）を、もう一度起こさない
  denied "main の上ではコミットしません" "cd $TMP/wt; true | { cd $REPO; git commit -m x; }" \
    "cd $TMP/wt; true | { cd $REPO; git commit -m x; } && :"
  # & を含むリダイレクト（&>）、&& の後の改行、( ) の中の cd、case の ;& は、外に効く・効かないを正しく読む
  allowed "cd $TMP/wt &> /dev/null && git commit -m x" "$(printf 'cd %s &&\ngit commit -m x' "$TMP/wt")" \
    "true | (cd $TMP/wt; git commit -m x)" "case x in x) cd $TMP/wt ;& y) : ;; esac; git commit -m x"
}

@test "case のパターンの ) は括弧を閉じない" {
  git worktree add -q -b feat/21-x "$TMP/wt"
  denied "main の上ではコミットしません" "(case x in a) :;; esac; cd $TMP/wt); git commit -m x" \
    "(case x in (a) :;; b) (cd /tmp);; esac; cd $TMP/wt); git commit -m x"
  allowed "(case x in a) :;; esac; cd $TMP/wt && git commit -m x)"
}

@test "算術式の << はヒアドキュメントとみなさない" {
  git checkout -q -b feat/21-x
  # $((...)) はフックに渡す文字として書く
  # shellcheck disable=SC2016
  denied "強制 push" "$(printf 'x=$((1<<2))\ngit push --force')" "$(printf '(( x = 1 << 2 ))\ngit push --force')" \
    "$(printf '((x = (1 + 2) << 3))\ngit push --force')"
}

@test "(( で始まる入れ子のサブシェルは、算術式とみなさずに調べる" {
  git checkout -q -b feat/21-x
  denied "強制 push" "((git push -f) || true)" "((cd /tmp && ls) && git push -f)"
}

@test "長いコマンドでも速く終わる" {
  git checkout -q -b feat/21-x
  msg="$(head -c 50000 /dev/zero | tr '\0' a | fold -w 76)"
  words="$(printf 'w%d ' $(seq 1 10000))"
  # 壁時計の10秒は、bats を並列に実行すると CPU の取り合いで延びて落ちた（#125）。
  # 解析そのものの重さを見るために、フックを動かす間の CPU 時間（ユーザー + システム。子プロセスを含む）で測る。
  # CPU を使わない待ちや停止は見えないので、壁時計にも大きめの上限を置く
  local TIMEFORMAT='%U %S' c
  : >"$TMP/cpu"
  SECONDS=0
  for c in "git commit -m \"$msg\"; git push -f" "echo $words; git push -f" \
    "$(printf 'git commit -F - <<EOF\n%s\nEOF\ngit push -f' "$msg")"; do
    { time run_hook "$c"; } 2>>"$TMP/cpu"
    [ "$status" -eq 2 ] || fail "止めなかった（$status）: ${c:0:80}"
    assert_output --partial "強制 push"
  done
  local cpu
  cpu="$(awk '{ t += $1 + $2 } END { printf "%.1f", t }' "$TMP/cpu")"
  awk -v t="$cpu" 'BEGIN { exit !(t < 10) }' || fail "CPU 時間で ${cpu} 秒かかった"
  [ "$SECONDS" -lt 120 ] || fail "壁時計で ${SECONDS} 秒かかった"
}

@test "ヒアドキュメントの後ろのコマンドは調べる" {
  git checkout -q -b feat/21-x
  denied "強制 push" "$(printf 'git commit -F - <<EOF\nfix: x\nEOF\ngit push -f')"
}

@test "リポジトリの外や、行き先の分からない cd の後は、ブランチでは止めない" {
  allowed "cd $TMP && git commit -m x" "cd \$SOMEWHERE && git commit -m x"
}

@test "規約に合わない名前でブランチを作るコマンドは、止めずに警告する" {
  warned foo \
    "git switch -c foo" \
    "git switch -C foo main" \
    "git switch --create foo" \
    "git switch --create=foo" \
    "git switch -qcfoo" \
    "git switch --orphan foo" \
    "git checkout -b foo" \
    "git checkout -qB foo origin/main" \
    "git checkout --orphan=foo" \
    "git branch foo" \
    "git branch -f foo main" \
    "git branch --track foo origin/main" \
    "git worktree add -b foo ../wt" \
    "git worktree add -f -B foo ../wt main" \
    "git -C $REPO switch -c foo" \
    "git fetch && git switch -c foo"
  run_hook "git switch -c foo"
  assert_output --partial "branch.pattern（{type}/{issue_number}-{slug}）の形になっていません"
  assert_output --partial "task-start"
  warned Feat/1-x "git switch -c Feat/1-x"
}

@test "ブランチを作るオプションを略して書いても、git と同じに読んで警告する" {
  warned foo "git switch --cre foo" "git switch --force-c foo" "git switch --orph=foo" "git checkout --orph foo" \
    "git branch --forc foo main" "git branch --tr foo origin/main"
  # switch の --force（--discard-changes）は値を取らないので、次の語を作るブランチと読まない
  silent "git switch --force foo"
}

@test "1つのコマンドで複数のブランチを作れば、まとめて警告する" {
  run_hook "git branch foo && git branch feat/1-ok && git branch bar"
  assert_success
  assert_output --partial "ブランチ名 foo は規約に合いません"
  assert_output --partial "ブランチ名 bar は規約に合いません"
  refute_output --partial "feat/1-ok"
}

@test "規約に合う名前や、ブランチを作らない git のコマンドでは何も出さない" {
  silent \
    "git switch -c feat/21-add-login" \
    "git checkout -b fix/3-typo" \
    "git branch docs/4-readme main" \
    "git worktree add -b feat/5-x ../wt" \
    "git status" \
    "git branch" \
    "git branch -a" \
    "git branch -vv" \
    "git branch -d foo" \
    "git branch -D foo" \
    "git branch -m foo" \
    "git branch --list 'f*'" \
    "git branch -u origin/foo foo" \
    "git switch foo" \
    "git switch -" \
    "git checkout foo" \
    "git checkout -- foo" \
    "git checkout -p foo" \
    "git worktree add ../wt foo" \
    "git worktree list" \
    "echo git branch foo"
  # 展開前の変数の名前は確かめない
  # shellcheck disable=SC2016
  silent 'git switch -c "$name"' 'git branch $(echo foo)'
}

@test "ブランチ名は、操作する先のリポジトリの設定で確かめる" {
  git init -q -b main "$TMP/other"
  mkdir -p "$TMP/other/.claude/dev-workflow"
  echo '{"branch": {"pattern": "{type}-{issue_number}/{slug}"}}' >"$TMP/other/.claude/dev-workflow/config.json"
  silent "git -C $TMP/other switch -c feat-1/x" "cd $TMP/other && git branch feat-1/x"
  warned feat/1-x "git -C $TMP/other switch -c feat/1-x"
  warned feat-1/x "git switch -c feat-1/x"
}

@test "設定を読めないときや、リポジトリの外では何も出さない" {
  echo '{' >.claude/dev-workflow/config.json
  silent "git switch -c foo"
  rm .claude/dev-workflow/config.json
  silent "cd $TMP && git switch -c foo"
}

@test "ブランチ名を警告しても、main を守る判断は変わらない" {
  denied "main の上ではコミットしません" "git branch foo && git commit -m x"
  denied "強制 push" "git switch -c foo && git push -f"
}

@test "base_branch や、手元・リモートに既にあるブランチの名前は確かめない" {
  git branch wip
  git update-ref refs/remotes/origin/dependabot/npm/foo HEAD
  silent \
    "git switch -C main origin/main" \
    "git checkout -B main origin/main" \
    "git branch -f main origin/main" \
    "git branch -f wip main" \
    "git switch -c dependabot/npm/foo origin/dependabot/npm/foo" \
    "git worktree add -b dependabot/npm/foo ../wt origin/dependabot/npm/foo"
  # 名前の一部だけが同じリモートのブランチでは、確かめる
  warned npm/foo "git switch -c npm/foo"
}

@test "git branch のまとめた短いオプションや --color の後ろの名前も確かめる" {
  warned bad "git branch -ft bad origin/main" "git branch -qf bad" "git branch --no-color bad" "git branch --color=always bad"
  silent "git branch -fd bad" "git branch -tm bad"
}

@test "git branch の名前の後ろに、作らないオプションがあれば確かめない" {
  silent "git branch bar -d" "git branch bar -D" "git branch 'f*' --list" "git branch bar -m baz" "git branch bar --contains main"
  warned bar "git branch bar main -f" "git branch bar -- main"
}

@test "導入していないリポジトリでは、main の上の commit・強制 push も、ブランチ名も止めない" {
  rm .claude/dev-workflow/config.json
  # ユーザーの層の設定も読まない（base_branch を develop にしても、develop の上の commit を止めない）
  echo '{"base_branch": "develop"}' >"$WORKFLOW_USER_DIR/config.json"
  silent "git commit -m x" "git push origin main" "git push --force" "git switch -c foo"
  git switch -q -c develop
  silent "git commit -m x"
}

@test "操作する先のリポジトリが導入したものかで判断する" {
  git init -q -b main "$TMP/other"
  silent "git -C $TMP/other commit -m x" "cd $TMP/other && git push --force"
  denied "main の上ではコミットしません" "cd $TMP/other && cd $REPO && git commit -m x"
  mark_set_up "$TMP/other"
  denied "main の上ではコミットしません" "git -C $TMP/other commit -m x"
}

@test "ワークツリーにチームの設定が無くても、メインのワークツリーにあれば守る" {
  # 初期設定をコミットする前に作ったワークツリーには、チームの設定が無い
  git worktree add -q "$TMP/wt" -b feat/1-x
  [ ! -f "$TMP/wt/.claude/dev-workflow/config.json" ]
  denied "強制 push" "cd $TMP/wt && git push --force"
  denied "main へは push しません" "cd $TMP/wt && git push origin feat/1-x:main"
}

@test "操作する先のディレクトリが分からないときは、今までどおり調べる" {
  rm .claude/dev-workflow/config.json
  denied "強制 push" "cd - && git push --force"
}

@test "--git-dir・--work-tree・GIT_DIR などで指したリポジトリや .git の中でも、その対象が導入したリポジトリかで判断する" {
  git init -q -b main "$TMP/other"
  # 導入したリポジトリ（REPO）を、導入していないディレクトリ（other）などから指す
  denied "強制 push" \
    "cd $TMP/other && git --git-dir=$REPO/.git push --force" \
    "cd $TMP/other && git --git-dir $REPO/.git --work-tree $REPO push --force" \
    "cd $TMP/other && GIT_DIR=$REPO/.git git push --force" \
    "cd $TMP/other && env GIT_DIR=$REPO/.git git push --force" \
    "cd $TMP && GIT_DIR=repo/.git GIT_WORK_TREE=repo git push --force" \
    "cd $REPO/.git && git push --force" \
    "cd $REPO/.git/refs && git push --force"
  denied "main へは push しません" "cd $TMP/other && GIT_DIR=$REPO/.git git push origin main"
  denied "main の上ではコミットしません" "cd $TMP/other && git --git-dir=$REPO/.git --work-tree=$REPO commit -m x"
  # 導入していないリポジトリ（other）を、導入したリポジトリ（REPO）の中から指す
  silent \
    "git --git-dir=$TMP/other/.git push --force" \
    "GIT_DIR=$TMP/other/.git git push --force" \
    "cd $TMP/other/.git && git push --force" \
    "git --git-dir=$TMP/other/.git commit -m x"
}

@test "base_branch とブランチ名の規約は、今のディレクトリではなく、操作の対象のリポジトリの設定から読む" {
  git init -q -b develop "$TMP/dev"
  mark_set_up "$TMP/dev"
  echo '{"base_branch": "develop"}' >"$TMP/dev/.claude/dev-workflow/config.json"
  git -C "$TMP/dev" commit -q --allow-empty -m init
  # 今のディレクトリ（REPO）の base_branch は main
  denied "develop へは push しません" \
    "GIT_DIR=$TMP/dev/.git GIT_WORK_TREE=$TMP/dev git push origin develop" \
    "git --git-dir $TMP/dev/.git --work-tree $TMP/dev push origin develop" \
    "git --git-dir=$TMP/dev/.git push origin develop"
  denied "develop の上ではコミットしません" "cd $TMP && GIT_DIR=dev/.git GIT_WORK_TREE=dev git commit -m x"
  silent "git --git-dir=$TMP/dev/.git push origin main"
  # 導入したリポジトリを、リポジトリの外から --git-dir で指しても、その規約でブランチ名を確かめる
  warned foo "cd $TMP && git --git-dir=$REPO/.git switch -c foo"
}

@test "ユーザーの層の base_branch は、導入していないリポジトリを --git-dir・GIT_DIR で指したときにも効かない" {
  echo '{"base_branch": "develop"}' >"$WORKFLOW_USER_DIR/config.json"
  git init -q -b develop "$TMP/other"
  git -C "$TMP/other" commit -q --allow-empty -m init
  # 今のディレクトリ（REPO）は導入したリポジトリなので、ここではユーザーの層を読む
  silent "git --git-dir=$TMP/other/.git commit -m x" "GIT_DIR=$TMP/other/.git git push origin develop"
}

@test "--separate-git-dir のリポジトリは、作業ツリーからはそのチームの設定で、外から指したときは HEAD にコミットしたチームの設定で判断する" {
  git init -q -b main --separate-git-dir "$TMP/sep.git" "$TMP/sep"
  mark_set_up "$TMP/sep"
  denied "main の上ではコミットしません" \
    "cd $TMP/sep && git commit -m x" \
    "cd $TMP/sep && GIT_WORK_TREE=. git commit -m x" \
    "cd $TMP/sep && git --work-tree=. commit -m x"
  # 外から git のディレクトリだけで指すと、作業ツリーは分からない（git がメインのワークツリーを記録していない）
  silent "cd $TMP && git --git-dir=$TMP/sep.git commit -m x"
  git -C "$TMP/sep" add .claude/dev-workflow/config.json
  git -C "$TMP/sep" commit -q -m setup
  denied "main の上ではコミットしません" "cd $TMP && git --git-dir=$TMP/sep.git commit -m x"
}

@test "サブモジュールは、サブモジュールのチームの設定で判断する（そのワークツリーや、外から指したときも）" {
  make_submodule
  git -C "$TMP/super/sm" switch -q main
  mark_set_up "$TMP/super/sm"
  git -C "$TMP/super/sm" worktree add -q "$TMP/smwt" -b feat/1-x
  denied "main の上ではコミットしません" \
    "cd $TMP/super/sm && git commit -m x" \
    "cd $TMP && GIT_DIR=super/.git/modules/sm git commit -m x"
  # サブモジュールのワークツリーにチームの設定が無くても、メインのワークツリー（super/sm）にあれば守る
  denied "強制 push" "cd $TMP/smwt && git push --force"
  # 上のリポジトリ（super）は導入していない
  silent "cd $TMP/super && git push --force"
}

@test "bare リポジトリは、HEAD にチームの設定がコミットされているかで判断する（関係のないミラーの移行は止めない）" {
  git clone -q --mirror "$REPO" "$TMP/mirror.git"
  silent \
    "cd $TMP/mirror.git && git push --mirror ../elsewhere.git" \
    "git -C $TMP/mirror.git push --force" \
    "GIT_DIR=$TMP/mirror.git git push --mirror ../elsewhere.git"
  # 導入したリポジトリ（チームの設定をコミットしたもの）のミラーは守る
  git add .claude/dev-workflow/config.json
  git commit -q -m setup
  git clone -q --mirror "$REPO" "$TMP/mirror2.git"
  denied "強制 push" "cd $TMP/mirror2.git && git push --mirror ../elsewhere.git"
}
@test "CDPATH を export していても、--git-dir・.git の中・ワークツリーで、対象のリポジトリを求められる" {
  git init -q -b main "$TMP/other"
  git worktree add -q "$TMP/wt" -b feat/1-x
  export CDPATH=.
  denied "強制 push" \
    "cd $TMP/other && git --git-dir=$REPO/.git push --force" \
    "cd $REPO/.git && git push --force" \
    "cd $TMP/wt && git push --force"
  silent "git --git-dir=$TMP/other/.git push --force"
}

@test "--git-dir・GIT_DIR の値の先頭の ~・\$HOME を展開して、対象のリポジトリを求める" {
  export HOME="$TMP"
  git init -q -b main "$TMP/other"
  # 導入していないリポジトリは止めない
  # shellcheck disable=SC2016
  silent 'GIT_DIR=~/other/.git git push --force' 'git --git-dir=$HOME/other/.git push --force' 'git --git-dir ${HOME}/other/.git push --force'
  # 導入したリポジトリは守る
  # shellcheck disable=SC2016
  denied "強制 push" 'cd ~/other && GIT_DIR=~/repo/.git git push --force' 'cd ~/other && git --git-dir=$HOME/repo/.git push --force'
}

@test "ワークツリーの git のディレクトリを GIT_DIR で指したときは、今のディレクトリのワークツリーではなく、指したワークツリーの設定で判断する" {
  git worktree add -q "$TMP/wt" -b develop
  mkdir -p "$TMP/wt/.claude/dev-workflow"
  echo '{"base_branch": "develop"}' >"$TMP/wt/.claude/dev-workflow/config.json"
  git -C "$TMP/wt" add .claude/dev-workflow/config.json
  git -C "$TMP/wt" commit -q -m setup
  # 今のディレクトリ（REPO）の base_branch は main。対象（wt）は develop の上で、base_branch は develop
  denied "develop の上ではコミットしません" "GIT_DIR=$REPO/.git/worktrees/wt git commit -m x"
}

@test "ワークツリーの git のディレクトリを指したとき、そのワークツリーにチームの設定が無くても、メインのワークツリーにあれば守る" {
  # 初期設定より前に作ったブランチのワークツリー（チームの設定がコミットされていない）
  git worktree add -q "$TMP/wt" -b old
  denied "強制 push" "GIT_DIR=$REPO/.git/worktrees/wt git push --force" "git --git-dir=$TMP/wt/.git push --force"
}

@test "GIT_WORK_TREE で同じリポジトリの別のワークツリーを指しても、そのワークツリーの設定では判断しない" {
  git worktree add -q "$TMP/wt" -b feat/1-x
  mkdir -p "$TMP/wt/.claude/dev-workflow"
  echo '{"base_branch": "develop"}' >"$TMP/wt/.claude/dev-workflow/config.json"
  # git のディレクトリ（HEAD）は REPO（main の上）のもの。base_branch も REPO の設定（main）で判断する
  denied "main の上ではコミットしません" "GIT_WORK_TREE=$TMP/wt git commit -m x"
}

@test "--opt=値 の ~ はシェルが展開しないので展開せず、cd・git -C の先の \$HOME は展開する" {
  export HOME="$TMP"
  git init -q -b main "$TMP/other"
  # git には ~/other/.git がそのまま渡り、リポジトリが見つからないので、守りを外さないよう調べる
  denied "強制 push" "git --git-dir=~/other/.git push --force"
  # 導入していないリポジトリを、cd・git -C の $HOME で指せば止めない
  # shellcheck disable=SC2016
  silent 'cd $HOME/other && git push --force' 'git -C ${HOME}/other push --force'
}

@test "--work-tree・GIT_WORK_TREE の値の ~・\$HOME も展開し、値が \$HOME だけでも展開する" {
  export HOME="$TMP"
  git init -q -b main "$TMP/other"
  git init -q -b main --separate-git-dir "$TMP/sep.git" "$TMP/sep"
  mark_set_up "$TMP/sep"
  # 作業ツリーを展開して求められれば、そのルートの規約でブランチ名を確かめる
  # shellcheck disable=SC2016
  warned foo 'cd ~/other && git --git-dir $HOME/sep.git --work-tree ~/sep switch -c foo' \
    'cd ~/other && GIT_DIR=$HOME/sep.git GIT_WORK_TREE=${HOME}/sep git switch -c foo'
  # 値が $HOME だけの作業ツリー（dotfiles の bare リポジトリの使い方）
  git init -q --bare "$TMP/dot.git"
  # shellcheck disable=SC2016
  silent 'git --git-dir=$HOME/dot.git --work-tree=$HOME push --force'
  git add .claude/dev-workflow/config.json
  git commit -q -m setup
  git clone -q --bare "$REPO" "$TMP/dot2.git"
  # shellcheck disable=SC2016
  denied "強制 push" 'git --git-dir=$HOME/dot2.git --work-tree=$HOME push --force'
}

@test "ルートが分からない対象は、HEAD にコミットしたチームの設定、ユーザーの層の順に base_branch を読み、ブランチ名は確かめない" {
  git init -q -b develop --separate-git-dir "$TMP/sep.git" "$TMP/sep"
  mkdir -p "$TMP/sep/.claude/dev-workflow"
  echo '{"base_branch": "develop"}' >"$TMP/sep/.claude/dev-workflow/config.json"
  git -C "$TMP/sep" add .claude/dev-workflow/config.json
  git -C "$TMP/sep" commit -q -m setup
  echo '{"base_branch": "release"}' >"$WORKFLOW_USER_DIR/config.json"
  # チームの設定（develop）がユーザーの層（release）より優先される
  denied "develop の上ではコミットしません" "cd $TMP && git --git-dir=$TMP/sep.git commit -m x"
  silent "cd $TMP && git --git-dir=$TMP/sep.git push origin main" "cd $TMP && git --git-dir=$TMP/sep.git switch -c foo"
  # チームの設定が base_branch を決めていなければ、ユーザーの層の値を使う
  echo '{}' >"$REPO/.claude/dev-workflow/config.json"
  git add .claude/dev-workflow/config.json
  git commit -q -m setup
  git clone -q --mirror "$REPO" "$TMP/mirror.git"
  denied "release へは push しません" "cd $TMP/mirror.git && git push origin release"
}

@test "対象のリポジトリが見つからないときは、守りを外さないよう調べる" {
  mkdir "$TMP/plain"
  denied "強制 push" "cd $TMP/plain && git push --force" "cd $TMP/plain && GIT_DIR=$TMP/nowhere git push --force"
}

@test "積んだ場所が無い popd は場所を移さない（その後でも、main への commit を止める）" {
  denied "main の上ではコミットしません" "popd; git commit -m x" "popd && git commit -m x"
  denied "強制 push" "popd; git push -f"
}

@test "pushd で積んだ場所を追い、popd で戻った先で判断する" {
  git worktree add -q -b feat/21-x "$TMP/wt"
  denied "main の上ではコミットしません" \
    "pushd ../wt && git push && popd && git commit -m x" \
    "pushd $TMP/wt; popd; git commit -m x" \
    "pushd $TMP/wt && pushd $TMP && popd && popd && git commit -m x" \
    "cd $TMP/wt && pushd $REPO && popd -n && git commit -m x"
  allowed "pushd ../wt && pushd $REPO && popd && git commit -m x" \
    "cd $TMP/wt && pushd $REPO && popd && git commit -m x" \
    "cd $TMP/wt && pushd $REPO && popd +0 && git commit -m x" \
    "pushd $TMP/wt && dirs -c && popd; git commit -m x" "pushd $TMP/wt && dirs -l -c +0 && popd; git commit -m x"
  # dirs は、まとめ書き（-cl）・ほかのオプション・-- の後ろの語があると失敗して、スタックを変えない
  denied "main の上ではコミットしません" "pushd $TMP/wt && dirs -- -c; popd; git commit -m x" \
    "pushd $TMP/wt && dirs -x -c; popd; git commit -m x" "pushd $TMP/wt && dirs -cl; popd; git commit -m x"
}

@test "( ) の中で積んだ・戻した場所は、括弧の外に効かない" {
  git worktree add -q -b feat/21-x "$TMP/wt"
  denied "main の上ではコミットしません" \
    "pushd $TMP/wt && (popd && git commit -m x)" \
    "(pushd $TMP/wt); popd; git commit -m x" \
    "pushd $TMP/wt && (popd; pushd $TMP/wt) && popd && git commit -m x"
  allowed "pushd $TMP/wt && (popd) && git commit -m x" "cd $TMP/wt && (pushd $REPO) && popd; git commit -m x"
}

@test "引数の無い pushd・pushd -n・pushd +N/-N・popd +N/-N を、シェルと同じに扱う" {
  git worktree add -q -b feat/21-x "$TMP/wt"
  # 引数の無い pushd は、積んだ場所が無ければ失敗し、あれば上の2つを入れ替える（$HOME へは移らない）
  denied "main の上ではコミットしません" "pushd; git commit -m x" "pushd $TMP/wt && pushd && git commit -m x" \
    "pushd -n $TMP/wt && git commit -m x" "pushd -n ../wt && popd -n && popd; git commit -m x"
  allowed "pushd -n $TMP/wt && pushd && git commit -m x" "pushd -n ../wt && popd && git commit -m x"
  # pushd -n で積んだ相対パスは、移るときの場所から解決する（シェルと同じ）
  allowed "pushd -n wt && cd .. && popd && git commit -m x"
  # +N は左から、-N は右から数えた場所を先頭に回して移る（dirs -v の順。0 は今の場所）
  denied "main の上ではコミットしません" "pushd $TMP/wt && pushd +1 && git commit -m x" \
    "pushd $TMP/wt && pushd -0 && git commit -m x" "pushd $TMP/wt && pushd $TMP && pushd -0 && git commit -m x"
  allowed "pushd $TMP/wt && pushd $TMP && pushd +1 && git commit -m x" "pushd $TMP/wt && pushd +1 && pushd -0 && git commit -m x"
  # 範囲の外の番号は失敗し、移らない
  denied "main の上ではコミットしません" "pushd +1; git commit -m x" "pushd $TMP/wt && pushd +2; pushd +1; git commit -m x"
  # popd +N は、その場所を取り除くだけで、+0（今の場所）でなければ移らない
  allowed "pushd $TMP/wt && popd +1 && git commit -m x" "pushd $TMP/wt && pushd $TMP && popd -0 && popd && git commit -m x"
  denied "main の上ではコミットしません" "pushd $TMP/wt && popd -1 && git commit -m x"
  # 引数の無い pushd -n は何もしない
  denied "main の上ではコミットしません" "pushd $TMP/wt && pushd -n && popd && git commit -m x"
  # pushd -n +N は、今の場所を残したまま、積んだ場所だけを回す
  denied "main の上ではコミットしません" "pushd -n $TMP/wt && pushd -n $TMP && pushd -n +1 && git commit -m x"
  allowed "pushd -n $TMP/wt && pushd -n $TMP && pushd -n +1 && popd && git commit -m x"
}

@test "前に付くだけのコマンド（command・exec・time・nohup・env）を飛ばして、git を調べる" {
  git checkout -q -b feat/21-x
  denied "強制 push" "command git push -f" "exec git push -f" "time git push -f" "nohup git push -f" "env git push -f" \
    "env FOO=1 git push -f" "FOO=1 nohup git push -f"
}

@test "前に付くコマンドのオプション（timeout・nice・time -p・env・command・exec）を飛ばして、git を調べる" {
  git checkout -q -b feat/21-x
  denied "強制 push" \
    "timeout 60 git push -f" "timeout -s KILL 60 git push -f" "timeout --signal=KILL -k5 --foreground 60 git push -f" \
    "timeout --sig KILL 60 git push -f" "timeout -- 60 git push -f" \
    "nice git push -f" "nice -n 5 git push -f" "nice -n5 git push -f" "nice -5 git push -f" "nice --adjustment=5 git push -f" \
    "time -p git push -f" \
    "env -u FOO git push -f" "env -i git push -f" "env - git push -f" "env -iu FOO git push -f" "env --unset=FOO git push -f" \
    "env --unset FOO git push -f" "env -0 -v git push -f" "env -S 'git push -f'" "env -S '-u FOO' git push -f" \
    "command -p git push -f" "exec -a x git push -f" "exec -cl git push -f" \
    "timeout 60 nice -n 5 env -u FOO FOO=1 git push -f" "nohup -- git push -f" "command -- git push -f"
  # command -v・-V は、コマンドを実行しない
  allowed "command -v git push -f" "command -pV git push -f"
}

@test "env -S の値は、env と同じく引用符とエスケープを解いて分ける" {
  git checkout -q -b feat/21-x
  denied "main へは push しません" "env -S \"git push origin 'main'\"" "env -S 'git push origin \"main\"'" \
    "env -S 'git push origin ma\\in'" "env -S 'git push \"origin\" \"feat/21-x:main\"'"
  # '…' の中では \\ と \' だけを解く（GNU env と同じ）。'a\'' と main は別の語
  local c
  c="$(cat <<'EOF'
env -S "git push origin 'a\\'' main"
EOF
)"
  denied "main へは push しません" "$c"
  # '…' の中の \\ は \（env が受け取る値は git push origin 'a\\' main。'a\\' と main は別の語）
  c="$(cat <<'EOF'
env -S "git push origin 'a\\\\' main"
EOF
)"
  denied "main へは push しません" "$c"
  # "…" の外の \_ は区切り、中では空白
  denied "強制 push" "env -S 'git\\_push\\_-f'"
  allowed "env -S 'git push origin \"x\\_main\"'"
}

@test "env -i・env -・env -u で消した GIT_DIR などは、対象を求めるときに使わない" {
  git init -q -b main "$TMP/other"
  # 導入していないリポジトリ（other）を指した GIT_DIR を消すので、今のディレクトリ（main の上）で判断する
  denied "main の上ではコミットしません" "GIT_DIR=$TMP/other/.git env -i git commit -m x" \
    "GIT_DIR=$TMP/other/.git env - git commit -m x" "GIT_DIR=$TMP/other/.git env -u GIT_DIR git commit -m x" \
    "GIT_DIR=$TMP/other/.git env --unset=GIT_DIR git commit -m x" "GIT_DIR=$TMP/other/.git env --ignore-env git commit -m x"
  # 消した後の代入と、ほかの変数を消すときは、GIT_DIR が効く
  silent "env -i GIT_DIR=$TMP/other/.git git commit -m x" "GIT_DIR=$TMP/other/.git env -u FOO git commit -m x"
}

@test "env -C の値をくっつけて書いたとき（-C~/x・--chdir=~/x）は、シェルと同じく ~ を展開しない" {
  export HOME="$TMP/home"
  # 文字どおりの ~/repo（$TMP/sub/~ → $TMP）は main の上のリポジトリ、展開した ~/repo は作業用のブランチのワークツリー
  mkdir -p "$TMP/sub"
  ln -s "$TMP" "$TMP/sub/~"
  git worktree add -q -b feat/21-x "$TMP/home/repo"
  denied "main の上ではコミットしません" "cd $TMP/sub && env -C~/repo git commit -m x" "cd $TMP/sub && env --chdir=~/repo git commit -m x"
  allowed "cd $TMP/sub && env -C ~/repo git commit -m x" "cd $TMP/sub && env --chdir ~/repo git commit -m x"
}

@test "env -C <dir> で移った先で、そのコマンドの git を判断する" {
  git worktree add -q -b feat/21-x "$TMP/wt"
  allowed "env -C $TMP/wt git commit -m x" "env -C ../wt git commit -m x" "env --chdir=$TMP/wt git commit -m x" \
    "env --chd ../wt nice git commit -m x" "env -iC../wt git commit -m x" "env -C $TMP env -C wt git commit -m x"
  # env -C は、そのコマンドだけに効く
  denied "main の上ではコミットしません" "env -C $TMP/wt true; git commit -m x" "cd $TMP/wt && env -C $REPO git commit -m x"
}

@test "外部のコマンドとして実行する cd・pushd・popd は、場所を移さない" {
  git worktree add -q -b feat/21-x "$TMP/wt"
  denied "main の上ではコミットしません" "env cd $TMP/wt; git commit -m x" "nohup pushd $TMP/wt; git commit -m x" \
    "timeout 5 cd $TMP/wt; git commit -m x"
  # builtin・command・time は、シェルの組み込みの cd を実行する
  allowed "command cd $TMP/wt && git commit -m x" "time cd $TMP/wt && git commit -m x" "builtin cd $TMP/wt && git commit -m x"
  # builtin・cd・nohup に不正なオプションがあると、シェルは失敗して、移らない・実行しない
  denied "main の上ではコミットしません" "builtin -x cd $TMP/wt; git commit -m x" "cd -x $TMP/wt; git commit -m x"
  allowed "cd -P $TMP/wt && git commit -m x" "cd -L -e $TMP/wt && git commit -m x" "nohup --help git commit -m x"
  denied "main の上ではコミットしません" "cd $TMP/wt && builtin cd $REPO && git commit -m x" \
    "cd $TMP/wt && builtin -- cd $REPO && git commit -m x"
}

@test "cd \"\" は移らない（引数の無い cd だけが \$HOME へ移る）" {
  # $HOME を作業用のブランチのワークツリーにして、$HOME へ移ったと読めば通してしまうようにする
  git worktree add -q -b feat/21-x "$TMP/wt"
  export HOME="$TMP/wt"
  denied "main の上ではコミットしません" "cd \"\"; git commit -m x" "cd ''; git commit -m x"
  # pushd "" は失敗し、pushd -n "" で積んだ場所へ戻っても移らない
  denied "main の上ではコミットしません" "pushd \"\"; git commit -m x" "pushd -n \"\" && popd && git commit -m x"
  allowed "cd; git commit -m x" "cd && git commit -m x"
}

@test "cd -- の後ろは、- で始まっても行き先として読む" {
  # $HOME は作業用のブランチのワークツリー、-r は main の上のリポジトリ（REPO）
  git worktree add -q -b feat/21-x "$TMP/wt"
  export HOME="$TMP/wt"
  ln -s "$REPO" "$TMP/-r"
  denied "main の上ではコミットしません" "cd $TMP && cd -- -r && git commit -m x" "cd $TMP && cd -L -- -r && git commit -m x"
}
