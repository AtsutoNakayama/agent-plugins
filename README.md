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
| `/dev-workflow:task-create` | 依頼の内容から Issue を起票し、type ラベルを付けて Project に追加する。Story Point は見積もりを提案し、確認してから設定する。先に終わらせる Issue があれば、本文の「依存」に `#N` を書き、GitHub の依存関係（blocked by）にも登録する |
| `/dev-workflow:task-start` | Issue の作業を始める。ブランチとワークツリー（`.claude/worktrees/<ブランチ名>`）を作り、自分に割り当てて In Progress に移す。確認を取らずに進め、結果を伝える |
| `/dev-workflow:commit` | 変更を Conventional Commits の規約に沿ってコミットする。メッセージを検証してからコミットし、main の上ではコミットしない |
| `/dev-workflow:review` | 作業中のブランチの変更を、組み込みの `/code-review` と独自のレビューの観点（下記）で並行してレビューし、指摘を1つの一覧にまとめる。反映する指摘を選ぶと、それだけを直してコミットする |
| `/dev-workflow:pr-create` | 作業用のブランチを push し、Issue に紐付けた PR を作る。タイトルは `<type>: <Issueのタイトル>`、本文は PR テンプレートに沿って書き、`Closes #N` を付けてラベルを引き継ぐ。確認してから push する |
| `/dev-workflow:task-finish` | PR がマージされた後の後片付け。マージを確かめ、ワークツリーとローカルのブランチを削除し、main を最新にする（`git pull --ff-only`）。確認を取らずに進め、作業が失われるとき（マージされていない、PR に入っていないコミット・未コミットの変更・サブモジュールの push していないコミットがある）は、何も消さずに止まる |

## レビューの観点

`/dev-workflow:review` は、次の3つの層に置いた観点ファイル（1ファイルに1観点の Markdown）を合わせて使います。同じ名前の観点があれば、上の層のファイルが使われます。

1. `<repo>/.claude/review/*.md`：リポジトリの観点（チームで共有する）
2. `~/.claude/review/*.md`：自分の観点（全リポジトリで使う）
3. `plugins/dev-workflow/review/*.md`：プラグインに同梱する共通の観点

```markdown
---
title: 一覧に出す1行の説明（必須）
---

サブエージェントへのレビューの指示。何を確かめ、どう指摘するかを書く。
```

- 観点の名前はファイル名（`.md` を除く）です。小文字の英数字と `-` だけを使います。
- 同梱の観点を使わないときは、上の層に同じ名前のファイルを置き、frontmatter に `enabled: false` と書きます（本文と `title` は省けます）。
- 使われる観点は `plugins/dev-workflow/scripts/review-perspectives.sh` で確かめられます。形式の誤ったファイルは警告を出して使いません。そのファイルと同じ名前の観点は、下の層にあっても使いません（`enabled: false` の書き間違いで、止めたつもりの観点が動かないようにするため）。

同梱の観点：

| 観点 | 内容 |
|---|---|
| `issue-requirements` | 変更が Issue の「やること」と「完了条件」を満たし、範囲外の変更が混ざっていないか |
| `docs-sync` | 振る舞いの変更に合わせて、ドキュメントとコメントが直されているか |

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

開発に参加するときの環境の準備・開発の流れ・テストは [CONTRIBUTING.md](CONTRIBUTING.md) を参照してください。
