# 開発への参加

このリポジトリを開発する人向けの手順とルールです。プラグインの使い方は [README](README.md)、設計は [docs/design.md](docs/design.md) を参照してください。

## 環境の準備

必要なもの：`git`、`gh`、`jq`、`shellcheck`、`bats`（bats-core）、`actionlint`（無ければ Docker で実行できます。下の「テストとチェック」）

テストの補助ライブラリ（bats-support・bats-assert）は git submodule で同梱しています。

```bash
git submodule update --init   # 初回だけ
```

開発中のプラグインを Claude Code に読み込んで試す方法は、README の「使い方」を参照してください。

## 開発の流れ

このリポジトリ自身も dev-workflow プラグインのワークフローで開発します。

1. **Issue を起票します**（`/dev-workflow:task-create`）。作業はすべて Issue から始めます。
2. **着手します**（`/dev-workflow:task-start`）。ブランチとワークツリー（`.claude/worktrees/<ブランチ名>`）ができるので、以後はその中で作業します。
3. **コミットします**（`/dev-workflow:commit`）。全部を直し終えてから1回でコミットするのではなく、論理的な区切り（1つの変更を仕上げてテストが通ったところ）ごとにコミットします。
4. **PR を出します**（`/dev-workflow:pr-create`）。出す前に、下の「テストとチェック」がすべて通ることを確かめます。
5. **後片付けをします**（`/dev-workflow:task-finish`）。PR がマージされたら、ワークツリーとローカルのブランチを削除し、main を最新にします。

Issue をやめることにしたときは、`/dev-workflow:task-cancel` を使います。理由と参照先をコメントして not planned（重複なら duplicate）で閉じ、着手していれば PR を閉じて、ブランチとワークツリーも削除します。

### コミットと PR の規約

- コミットメッセージは [Conventional Commits](https://www.conventionalcommits.org/ja/v1.0.0/)（`<type>(<scope>): <要約>`）で書きます。type は `plugins/dev-workflow/defaults/workflow.json` の `commit.types` のどれかです。
- PR のタイトルは `<type>: <Issueのタイトル>` とし、本文に `Closes #<Issue番号>` を付けます。
- マージはスカッシュのみです。main への直接 push・強制 push はルールセットとフックで禁止されています。
- プラグインのバージョンは release-please がリリース PR で上げます。`plugin.json` の `version` や `.release-please-manifest.json` を手で変えないでください。

## 書き方のルール

- **macOS 標準の bash 3.2 で動くように書きます**。連想配列（`declare -A`）、`mapfile` / `readarray`、`${var,,}` などの bash 4 以降の機能は使いません。スクリプトの先頭には `set -euo pipefail` を書きます。
- 日本語などの ASCII 以外の文字が変数の直後に続くときは、`"${var}」"` のように波括弧で囲みます（bash 3.2 は `"$var」"` の `」` のバイトまで変数名とみなします。CI で検査しています）。
- 設定・ガイド・レビューの観点・ラベルの定義は、`.claude/dev-workflow/` の下（`config.json`・`config.local.json`・`review/`・`labels.json`）を参照します。テストやスクリプトで古い置き場所（`.claude/workflow.json`・`.claude/review/` など）を参照すると、CI で失敗します（古い置き場所を知らせる `doctor.sh` とそのテストは除きます）。
- **スキルから呼ぶファイルは `plugins/dev-workflow/` の中に置きます**。プラグインとしてインストールされるのはこのディレクトリだけなので、外に置いたファイルは使う人の環境にありません。スキルからは `${CLAUDE_PLUGIN_ROOT}/scripts/...` のように参照します。
- **shellcheck を通します**。警告を抑えるときは、理由をコメントに書きます。
- スクリプトの出力は JSON、エラーは終了コードと1行のメッセージにします。初期設定用のスクリプト（`scripts/setup/`）は `--dry-run` に対応します（設計書 §10）。

## テストのルール

- **スクリプトを変えたら、bats のテスト（`tests/*.bats`）を足します**。GitHub を使うスクリプトは、`gh` を偽物（`tests/fake_gh.bash` など）に置き換えて、GitHub に触れずに試します。
- **不具合を修正するときは、その不具合がもう一度起きないことを確かめるテストを必ず足します**。修正前のコードでは失敗し、修正後に通ることを確かめてからコミットします。

## テストとチェック

PR を出す前に、次がすべて通ることを確かめます。どれも CI でも実行します（shellcheck・actionlint・`claude plugin validate` などは `.github/workflows/lint.yml`、bats は `.github/workflows/test.yml`）。ただし、`README.md`・`docs/`・Issue と PR のテンプレート（`.github/ISSUE_TEMPLATE/`・`.github/pull_request_template.md`）だけを変えた PR では、CI は動きません。

```bash
# tests/lib は外部のライブラリ（git submodule）なので対象にしない
find plugins tests -path tests/lib -prune -o -type f \( -name '*.sh' -o -name '*.bash' \) -print0 | xargs -0 shellcheck -x
shellcheck -s bash tests/*.bats
actionlint                         # 入っていなければ docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.12
bats tests/
TEST_BASH=/bin/bash bats tests/   # macOS では標準の bash 3.2 で確認する
claude plugin validate --strict .                     # マーケットプレイス
claude plugin validate --strict plugins/dev-workflow  # プラグイン本体（. だけではスキルなどは検査されない）
```

### Docker の bash 3.2 でテストする

macOS 以外でも、Docker の `bash:3.2` イメージで macOS 標準の bash 3.2 で動くことを確かめられます。リポジトリ・ワークツリーのどこで実行しても動きます。

```bash
root=$(cd "$(git rev-parse --git-common-dir)/.." && pwd)   # 元のリポジトリ
top=$(git rev-parse --show-toplevel)                       # 今いるリポジトリまたはワークツリー
docker run --rm -v "$root:$root" -v "$top:$top" -w "$top" bash:3.2 sh -c '
  apk add --no-cache jq git bats bash >/dev/null &&
  git config --global --add safe.directory "*" &&
  export PATH=/bin:/usr/bin:$PATH &&
  TEST_BASH=/usr/local/bin/bash bats tests/
'
```

- bats 本体は新しい bash（apk で入れる `/bin/bash`）で動かし、対象のスクリプトだけ bash 3.2（イメージの `/usr/local/bin/bash`）で動かします。イメージでは `/usr/local/bin` が PATH の先にあるので、`PATH` を並べ替えないと bats 本体も bash 3.2 で動き、日本語のテスト名を扱えずに失敗します。
- コンテナの中はファイルの持ち主が違うので、`safe.directory` を設定しないと git がリポジトリを使えません。
- ワークツリーの `.git` はファイルで、元のリポジトリの `.git/worktrees/` を指しています。ワークツリーだけをマウントすると `fatal: not a git repository` になるので、上のように元のリポジトリ全体とワークツリーを、どちらも同じパスでマウントします（ワークツリーがリポジトリの外にあっても動きます）。ワークツリーでは、先に `git submodule update --init` も実行しておきます。
