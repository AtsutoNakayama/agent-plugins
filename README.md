# agent-plugins

全リポジトリで共通に使う Claude Code のプラグイン（開発ワークフロー用のスキル群）と、GitHub リポジトリの初期設定スクリプト。

設計は [docs/design.md](docs/design.md) を参照。

## 使い方（開発中）

```bash
# プラグインを直接読み込んで Claude Code を起動する
claude --plugin-dir plugins/dev-workflow

# 実行環境と設定の確認
plugins/dev-workflow/scripts/doctor.sh
```

## スキル

| スキル | 内容 |
|---|---|
| `/dev-workflow:repo-setup` | リポジトリの初期設定（下記） |
| `/dev-workflow:task-create` | 依頼の内容から Issue を起票し、type ラベルを付けて Project に追加する。Story Point は見積もりを提案し、確認してから設定する |
| `/dev-workflow:task-start` | Issue の作業を始める。ブランチとワークツリー（`.claude/worktrees/<ブランチ名>`）を作り、自分に割り当てて In Progress に移す |
| `/dev-workflow:commit` | 変更を Conventional Commits の規約に沿ってコミットする。メッセージを検証してからコミットし、main の上ではコミットしない |
| `/dev-workflow:task-finish` | PR がマージされた後の後片付け。マージを確かめ、ワークツリーとローカルのブランチを削除し、main を最新にする（`git pull --ff-only`） |

## フック

プラグインを入れると、Claude Code が Bash で次の git の操作をしようとしたときに止めます（`hooks/guard-git.sh`）。守るブランチは設定の `base_branch`（既定は main）です。

- base_branch の上での `git commit`
- base_branch への `git push`（base_branch の上で push 先を書かずに push するときを含む）
- 強制 push（`--force` / `-f` / `+<refspec>` / `--mirror`）。`--force-with-lease` は許可する

`cd` や `git -C` で移った先のブランチで判断します。コマンドの文字列を簡易に解析するだけなので、`sh -c` や git の別名を通すと見逃します。最後の守りは GitHub のルールセット（下記）です。

## リポジトリの初期設定

Claude Code で `/dev-workflow:repo-setup` を実行すると、選択肢を聞き、予定を見せてから、以下をまとめて行います。スクリプトを直接実行することもできます。

`gh` に `project` スコープが必要です（`gh auth refresh -h github.com -s project` を普通のターミナルで実行）。

### まとめて行う

```bash
# ラベル・Project・マージ方法とルールセット・PR / Issue テンプレートを揃える（対象のリポジトリの中で実行）
plugins/dev-workflow/scripts/setup/setup-all.sh --dry-run
plugins/dev-workflow/scripts/setup/setup-all.sh
```

作ったファイル（テンプレート、`.claude/workflow.json`）はコミットされません。main は守られるので、PR でマージしてください。

### ラベル

```bash
# type ラベル（feat / fix など）を作成・更新し、GitHub の既定のラベルを削除する
plugins/dev-workflow/scripts/setup/setup-labels.sh

# 既定のラベルを残す・変更せずに予定だけを確認する
plugins/dev-workflow/scripts/setup/setup-labels.sh --keep-defaults
plugins/dev-workflow/scripts/setup/setup-labels.sh --dry-run
```

定義は `plugins/dev-workflow/defaults/labels.json`。リポジトリに `.claude/labels.json` を置くとそちらを使います（`--file` でも指定できます）。`--repo` で別のリポジトリを指定したときは、そのリポジトリの既定のブランチにある `.claude/labels.json` を読みます。

### Project

```bash
# Project を作成（同じ名前があれば再利用）し、Story Point の追加・Issue の取り込みを行う
plugins/dev-workflow/scripts/setup/setup-project.sh --write-config

# 既存の Project に接続する
plugins/dev-workflow/scripts/setup/setup-project.sh --number 3 --write-config

# 変更せずに、行う予定の操作だけを確認する
plugins/dev-workflow/scripts/setup/setup-project.sh --dry-run
```

Project に組み込みの自動追加（Auto-add to project）は API で有効にできないため、スクリプトが表示する URL の画面で1回だけ手動で有効にしてください。

### マージ方法とルールセット

```bash
# スカッシュのみ許可・マージ後にブランチを自動削除し、main への直接 push・強制 push・削除を禁止する
plugins/dev-workflow/scripts/setup/setup-repo.sh

# マージに承認を1つ必要にする（付けなければ今の値のまま）
plugins/dev-workflow/scripts/setup/setup-repo.sh --require-approval 1
```

ルールセット「dev-workflow」は管理者も例外にしません。守るブランチは設定の `base_branch`（既定は main）です。

## 開発

必要なもの：`git`、`gh`、`jq`、`shellcheck`、`bats`（bats-core）

テストの補助ライブラリ（bats-support・bats-assert）は git submodule で同梱しています。

```bash
git submodule update --init   # 初回だけ
shellcheck -x plugins/dev-workflow/scripts/*.sh plugins/dev-workflow/scripts/*/*.sh
bats tests/
TEST_BASH=/bin/bash bats tests/   # macOS では標準の bash 3.2 で確認する
claude plugin validate .
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
