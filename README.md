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

## 開発

必要なもの：`git`、`gh`、`jq`、`shellcheck`、`bats`

```bash
shellcheck -x plugins/dev-workflow/scripts/*.sh plugins/dev-workflow/scripts/lib/*.sh
bats tests/
TEST_BASH=/bin/bash bats tests/   # macOS では標準の bash 3.2 で確認する
claude plugin validate .
```
