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

## リポジトリの初期設定

### ラベル

```bash
# type ラベル（feat / fix など）を作成・更新し、GitHub の既定のラベルを削除する
scripts/setup-labels.sh

# 既定のラベルを残す・変更せずに予定だけを確認する
scripts/setup-labels.sh --keep-defaults
scripts/setup-labels.sh --dry-run
```

定義は `plugins/dev-workflow/defaults/labels.json`。リポジトリに `.claude/labels.json` を置くとそちらを使います（`--file` でも指定できます）。`--repo` で別のリポジトリを指定したときは、そのリポジトリの既定のブランチにある `.claude/labels.json` を読みます。

### Project

`gh` に `project` スコープが必要です（`gh auth refresh -h github.com -s project` を普通のターミナルで実行）。

```bash
# Project を作成（同じ名前があれば再利用）し、Story Point の追加・Issue の取り込みを行う
scripts/setup-project.sh --write-config

# 既存の Project に接続する
scripts/setup-project.sh --number 3 --write-config

# 変更せずに、行う予定の操作だけを確認する
scripts/setup-project.sh --dry-run
```

Project に組み込みの自動追加（Auto-add to project）は API で有効にできないため、スクリプトが表示する URL の画面で1回だけ手動で有効にしてください。

## 開発

必要なもの：`git`、`gh`、`jq`、`shellcheck`、`bats`

```bash
shellcheck -x plugins/dev-workflow/scripts/*.sh plugins/dev-workflow/scripts/lib/*.sh
bats tests/
TEST_BASH=/bin/bash bats tests/   # macOS では標準の bash 3.2 で確認する
claude plugin validate .
```
