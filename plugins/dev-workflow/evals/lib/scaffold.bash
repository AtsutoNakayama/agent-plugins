# shellcheck shell=bash
# eval のケースの準備のスクリプト（case.yaml の context.scaffold_script）が読み込む共通の処理。
# 準備のスクリプトは、--scaffold を付けたときだけ、サンドボックスの外で、空の作業用のディレクトリを今のディレクトリにして動く。
# ケースは、偽の gh（リポジトリの tests/eval/bin/gh）を使うので、tests/eval/run.sh から実行する。
#
# 使い方（ケースの fixture.sh）:
#   . "$(dirname "$0")/../lib/scaffold.bash"
#   eval_repo '{"project": {"owner": "me", "number": 4}}'
#   fake_gh 'issue list*' '[]'

# 作業用のディレクトリを、dev-workflow を導入した git リポジトリ（main に最初のコミットが1つ）にする。
# origin は作業用のディレクトリの中の bare のリポジトリ（.fake-remote.git）で、main を push してある（origin/main がある）。
# 偽の gh の表（.fake-gh/）も作り、リポジトリの名前（me/demo）・gh のバージョン・ログインしている人（me）の応答を入れる。
# .fake-gh/ と .fake-remote.git/ は .git/info/exclude で git の対象から外す。
# 使い方: eval_repo [.claude/dev-workflow/config.json の中身（既定 {}）]
eval_repo() {
  git init -q -b main .
  # 実行のたびに HOME が空になり、git の名前とメールアドレスが無いので、リポジトリに設定する（Claude のコミットにも使う）
  git config user.name "Eval"
  git config user.email "eval@example.com"
  mkdir -p .claude/dev-workflow
  printf '%s\n' "${1:-"{}"}" >.claude/dev-workflow/config.json
  printf '# demo\n' >README.md
  printf '.fake-gh/\n.fake-remote.git/\n' >>.git/info/exclude
  git add -A
  git commit -q -m "chore: 最初のコミット"
  git init -q --bare .fake-remote.git
  git remote add origin "$PWD/.fake-remote.git"
  git push -q -u origin main
  fake_gh_init
  fake_gh 'repo view*' '{"nameWithOwner": "me/demo", "url": "https://github.com/me/demo", "defaultBranchRef": {"name": "main"}}'
  fake_gh '--version*' 'gh version 2.96.0 (2026-07-02)'
  fake_gh 'api user*' '{"login": "me"}'
  fake_gh 'auth status*' 'github.com: Logged in to github.com account me'
}

# 偽の gh の表（.fake-gh/）を、空にして作る（tests/eval/bin/fake-gh.sh の表と記録の形式を参照）。
# 使い方: fake_gh_init
fake_gh_init() {
  rm -rf .fake-gh
  mkdir -p .fake-gh/res
  : >.fake-gh/routes
  : >.fake-gh/calls
  : >.fake-gh/writes
}

# 偽の gh の応答を、表の最後に足す（先に足したものが優先される）。
# 応答が空なら、何も出力しない（空の行も出さない）。
# 使い方: fake_gh <パターン（bash の case のパターン。引数を空白でつないだ文字列に当てる）> <応答> [終了コード（既定 0）]
fake_gh() {
  local n
  n="$(($(wc -l <.fake-gh/routes) + 1))"
  if [ -n "$2" ]; then printf '%s\n' "$2" >".fake-gh/res/${n}"; else : >".fake-gh/res/${n}"; fi
  printf '%s\t%s\t%s\n' "$1" "res/${n}" "${3:-0}" >>.fake-gh/routes
}

# Issue を1つ、gh issue view で読めるようにする。番号・#番号・URL のどれで指定しても、オプションが番号の前後どちらにあっても答える
# （1 の応答が 10 などに当たらないよう、番号の後ろは空白か終わりに限る）。
# 使い方: fake_issue <番号> <タイトル> <type ラベル> <本文>
fake_issue() {
  local json ref
  json="$(jq -n --argjson n "$1" --arg t "$2" --arg l "$3" --arg b "$4" \
    '{number: $n, title: $t, body: $b, state: "OPEN", url: "https://github.com/me/demo/issues/\($n)",
      labels: [{name: $l}], assignees: [], parent: null, subIssues: {nodes: [], totalCount: 0},
      subIssuesSummary: {total: 0, completed: 0, percentCompleted: 0}}')"
  for ref in "$1" "#$1" "https://github.com/me/demo/issues/$1"; do
    fake_gh "issue view ${ref}" "$json"
    fake_gh "issue view ${ref} *" "$json"
    fake_gh "issue view * ${ref}" "$json"
    fake_gh "issue view * ${ref} *" "$json"
  done
}

# GitHub に書き込む gh の呼び出しに、成功したように答える。書き込んだかは、偽の gh が .fake-gh/writes に記録するので、
# grader はそれが空かを確かめる（ここに無い書き込みも記録される）。ここでは、Claude が確認を取らずに書き込もうとしたときに、
# エラーで止まらず、書き込んだと思って進むようにする（止まると、書き込もうとしたことが返答から読み取りにくくなる）。
# プラグインのスクリプトが使う呼び出し（issue-create.sh の REST での起票など）と、Claude が直接使いそうなサブコマンドに答える
fake_gh_writes() {
  # issue-create.sh は、応答の labels に type ラベルがあるかを確かめるので、type ラベルを全部入れておく
  fake_gh 'api -X POST repos/me/demo/issues --input*' '{"number": 99, "id": 9900, "node_id": "I_99", "html_url": "https://github.com/me/demo/issues/99", "labels": [{"name": "feat"}, {"name": "fix"}, {"name": "refactor"}, {"name": "perf"}, {"name": "test"}, {"name": "docs"}, {"name": "build"}, {"name": "ci"}, {"name": "chore"}, {"name": "breaking"}]}'
  fake_gh 'api -X POST *' '{}'
  fake_gh 'api -X PATCH *' '{}'
  fake_gh 'api -X DELETE *' ''
  fake_gh 'issue create*' 'https://github.com/me/demo/issues/99'
  fake_gh 'pr create*' 'https://github.com/me/demo/pull/98'
  fake_gh 'issue edit*' ''
  fake_gh 'issue comment*' ''
  fake_gh 'issue close*' ''
  fake_gh 'pr edit*' ''
  fake_gh 'pr comment*' ''
  fake_gh 'pr close*' ''
  fake_gh 'pr merge*' ''
  fake_gh 'project item-add*' '{"id": "IT99"}'
  fake_gh 'project item-edit*' '{}'
}
