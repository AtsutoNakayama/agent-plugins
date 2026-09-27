---
name: repo-setup
description: リポジトリの初期設定（type ラベル、GitHub Project、スカッシュのみのマージとルールセット、PR / Issue テンプレート）を対話的に行う。新しいリポジトリで開発ワークフローを使い始めるときに使う。
disable-model-invocation: true
---

# リポジトリの初期設定

今いるリポジトリを、開発ワークフローで使える状態にする。実際の処理は `setup-all.sh` が行い、このスキルは選択肢を聞いて、予定を見せ、確認を取ってから実行する。

スクリプト（どれも JSON を出力する）:

- `${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh`：実行環境と認証の確認
- `${CLAUDE_PLUGIN_ROOT}/scripts/config.sh`：合わせた設定の出力
- `${CLAUDE_PLUGIN_ROOT}/scripts/setup/setup-all.sh`：初期設定をまとめて行う（`--help` で使い方）

## 手順

### 1. 実行環境を確かめる

`doctor.sh` を実行する。`ok` が `false` なら、失敗した項目と直し方を伝えて止める。

- `gh-project-scope` が失敗：普通のターミナルで `gh auth refresh -h github.com -s project` を実行してもらう
- `gh-auth` が失敗：`gh auth login` を実行してもらう

リポジトリの外にいるときも止める。

### 2. 選択肢を聞く

`config.sh` で今の設定を読み、決まっていないことだけを AskUserQuestion でまとめて聞く。

- **Project**：`project.number` が設定済みなら聞かない。無ければ「新しく作る（名前。既定はリポジトリ名）」か「既存の Project に接続する（番号）」か
- **GitHub の既定のラベル**（bug・enhancement など）：削除する（おすすめ）か残すか。削除すると、付いている Issue からも外れる
- **マージに必要な承認の数**：0（おすすめ。1人で開発するとき）か 1 以上か

### 3. 予定を見せる

選んだオプションに `--dry-run` を付けて `setup-all.sh` を実行し、`labels.actions`・`project.actions`・`repo.actions`・`templates` を、変わることが分かる短い一覧にして見せる。変更が無い項目は「変更なし」とまとめる。

ルールセットを作るときは、次のことも伝える。

- 以後、`repo.branch` へ直接 push できなくなり、PR が必須になる。管理者も例外にしない
- マージはスカッシュだけになる

### 4. 確認を取って実行する

実行してよいか確認を取る。承認されたら、同じオプションで `--dry-run` を外して実行する。失敗したら、標準エラーの1行のメッセージをそのまま伝える（例：非公開のリポジトリで、プランによってルールセットを使えない）。

### 5. 次にやることを伝える

出力の `next_steps` を伝える。

- **作ったファイル**（テンプレート、`.claude/workflow.json`）はコミットされていない。直接 push できないので、Issue を起票し、ブランチを切って PR にする
- **自動追加（Auto-add to project）** が無効なら、URL の画面で有効にしてもらう。有効にした後に `setup-all.sh --dry-run` をもう一度実行すると、`project.workflows.auto_add` が `true` になったか確かめられる
