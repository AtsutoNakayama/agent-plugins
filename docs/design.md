# 設計書：開発ワークフロー用プラグインと GitHub 初期設定

全リポジトリで共通に使う Claude Code のスキル群と、GitHub の初期設定スクリプトの設計。

## 1. 配布方法

- このリポジトリを **Claude Code のプラグインマーケットプレイス**にする（`.claude-plugin/marketplace.json`）。
- リポジトリは公開。リポジトリごとに異なる値（Project の番号、列名など）は設定ファイルに外出しする。
- プラグインは `dev-workflow` の1つにまとめる。レビューだけ使いたい人が出てきたら分割を検討する。
- チームに配るときは、対象リポジトリの `.claude/settings.json` に `extraKnownMarketplaces` と `enabledPlugins` を書く。

```
agent-plugins/
├── .claude-plugin/marketplace.json
├── plugins/dev-workflow/
│   ├── .claude-plugin/plugin.json
│   ├── skills/        # 各スキル
│   ├── hooks/         # ガードレール
│   ├── review/        # 共通のレビュー観点
│   └── scripts/       # スキルから呼ぶスクリプト（lib/common.sh を含む）
└── scripts/           # リポジトリの初期設定用（プラグインの外）
```

## 2. ブランチ運用とマージ

- GitHub Flow：main から短命のブランチを切り、PR を経て main にマージする。既定のマージ先は main（設定で変更できる）。
- マージは **スカッシュのみ許可**。マージしたブランチは自動で削除する。
- Issue との紐付けは PR 本文の `Closes #N`。マージすると Issue が閉じ、Project の自動化で Done に移る。
- マージは人間が行う。`"allow_ai_merge": true` で AI によるマージを許可できる。

## 3. 命名

- ブランチ名：`<type>/<issue番号>-<短い説明>`（例：`feat/12-add-login`）
- `type` は Issue の type ラベルから決める。起票時には type ラベルを必ず1つ付ける。
- **ブランチ名とワークツリー名は `[a-z0-9-/]` のみ**。日本語は含めない。短い説明は AI が英語で考え、スクリプトが整形・検証する。作れないときは `issue-<番号>` にする。
- ワークツリーの置き場所：`.claude/worktrees/<ブランチ名>`（設定で変更できる）。

## 4. GitHub Projects

- 基本はリポジトリごとに Project を1つ持つ。関連する複数のリポジトリで1つの Project を共有してもよい。
- 既定の列：`Todo / In Progress / Done`。
- 役割（どの場面で移すか）と列名の対応を設定ファイルに書く。スキルが自動で移すのは、役割が決まっている列だけ。利用者が追加した列（例：`Blocked`）へは、指示されたときに `task-status` で移す。

```jsonc
"status": {
  "todo": "Todo",
  "start": "In Progress",
  "pr_opened": null,   // 任意の項目。既定では PR 作成時に列を移さない
  "done": "Done"
}
```

- **Story Point**：数値の項目。値がフィボナッチ数列（1, 2, 3, 5, 8, 13）に含まれるかをスクリプトで検証する。起票時は AI が見積もりを提案し、ユーザーが確定する（空欄も可）。
- **Project への自動追加**：Project に組み込みの Auto-add を使う。有効にする API は無いので、Web の画面で1回だけ手動で有効にする。`setup-project.sh` が手順を表示し、有効になったかを API で確認する。
- `task-create` は起票の後、毎回 `addProjectV2ItemById` を呼んで項目の ID を取得する。既に追加済みなら既存の項目が返るだけなので、自動追加とは重複しない。
- 必要なトークンのスコープ：`project`（`gh auth refresh -s project`）。

## 5. ラベル

`feat / fix / hotfix / refactor / perf / test / docs / build / ci / chore` の10個。

- `ci` は CI/CD パイプラインの変更、`build` はビルドの設定・依存関係・Dockerfile の変更に使う。
- `hotfix` はコミットの type としては `fix` として扱う。
- GitHub の既定のラベルは削除する（オプションで残せる）。
- 定義は `labels.json` に置き、利用者が編集できる。

## 6. コミットと PR の書き方

- コミット：Conventional Commits（`<type>(<scope>): <要約>`）。各コミットには `Refs` を付けない。
- PR：タイトルは `<type>: <Issueのタイトル>`、本文は概要・変更点・確認方法・`Closes #N`。ラベルは Issue から引き継ぐ。通常の PR として作る（下書きにしない）。
- 言語：日本語が既定。
- スカッシュマージするので、コミットの規約は緩め、PR タイトルの規約は厳しくする。

### 書き方の設定（上が優先）

| 層 | 場所 |
|---|---|
| 1. 個人がそのリポジトリで上書き | `<repo>/.claude/workflow.local.json`（コミットしない） |
| 2. チームの規約 | `<repo>/.claude/workflow.json` と `<repo>/.claude/workflow/*.md` |
| 3. 既にある規約 | PR/Issue テンプレート、commitlint の設定、CONTRIBUTING.md |
| 4. 自分の好み | `~/.claude/workflow/` |
| 5. フォールバック | プラグインの既定 |

- 層は**項目ごとに合わせる**。上位の層が決めていない項目には、下位の層の値が効く。
- 構造化された設定（正規表現・type の一覧など）はスクリプトが検証に使い、文章のガイド（`*.md`）は AI が読む。ガイドどうしが矛盾したら、上位の層を優先する。

## 7. レビュー

- 観点は1ファイルに1観点の Markdown で書き、3つの層を足し合わせる：プラグインに同梱する共通の観点 / `~/.claude/review/` / `<repo>/.claude/review/`。
- 独自のレビュースキルは独自の観点だけを担当する（観点ごとにサブエージェントで並行してレビューする）。一般的なバグの検出は組み込みの `/code-review` に任せる。
- 指摘は1つの一覧にまとめ、反映するものをユーザーが選ぶ。
- PR のレビューも同じ観点を使い、選んだ指摘を該当行へのコメントとして投稿する。

## 8. スキル

| スキル | 内容 | 自動で呼ばれるか |
|---|---|---|
| `task-create` | Issue を起票し、Project に追加する | 明示的に呼んだときだけ |
| `task-start` | 自分に割り当て、In Progress に移し、ワークツリーとブランチを作る | 明示的に呼んだときだけ |
| `task-status` | 任意の列へ移す | 明示的に呼んだときだけ |
| `review` | ローカルのレビューと、反映するものの選択 | 自動でも可 |
| `review-pr` | PR のレビューと、該当行へのコメント投稿 | 明示的に呼んだときだけ |
| `review-perspective-add` | 観点ファイルを作る | 明示的に呼んだときだけ |
| `commit` | 規約に沿ったコミット | 自動でも可 |
| `pr-create` | push と PR 作成 | 明示的に呼んだときだけ |
| `task-finish` | ワークツリーとローカルブランチを削除し、main を最新にする（`git pull --ff-only`） | 明示的に呼んだときだけ |
| `workflow` | 今の段階を判断して次の段階へ進める | 明示的に呼んだときだけ |
| `repo-setup` | 初期設定を対話的に実行し、設定ファイルを作る | 明示的に呼んだときだけ |

外部に影響する操作をするスキルには `disable-model-invocation: true` を付ける。

## 9. ガードレール

1. **GitHub のルールセット**（`setup-repo.sh`）：main への直接 push の禁止と PR の必須化、強制 push と main の削除の禁止。承認の必須化はオプション（既定は無効）。
2. **Claude Code のフック**：main 上での commit と push をブロックする。`--force` をブロックする（`--force-with-lease` は許可）。ブランチ名が規約に合わないときは警告する。
3. **`workflow` スキル**：着手 → 実装 → ローカルレビュー → コミット → PR → PR レビュー → マージ（人間）→ 後片付け。

## 10. スクリプト

- **bash 3.2 でも動く書き方**（macOS の標準の bash に合わせる）＋ `gh` ＋ `jq`。`set -euo pipefail` を書き、`shellcheck` と `bats` を CI で実行する。
- 判断と文章の生成だけを AI が担当し、決まった手順で済む処理はスクリプトに切り出す（トークン削減のため）。
- 出力は JSON、エラーは終了コードと1行のメッセージ。初期設定用のスクリプトは `--dry-run` に対応する。

| プラグイン側（`plugins/dev-workflow/scripts/`） | 役割 |
|---|---|
| `doctor.sh` | 認証とスコープ、`jq` と bash のバージョン、設定ファイルを確認する |
| `config.sh` | 5つの層を合わせた設定を出力する |
| `issue-create.sh` | 起票、ラベルの付与、Project への追加、列と Story Point の設定 |
| `status-set.sh` | 列を移す |
| `branch-name.sh` | ブランチ名を作り、検証する |
| `task-start.sh` | ワークツリーの作成、割り当て、In Progress への移動 |
| `context.sh` | 今のブランチから Issue・PR・段階を割り出す |
| `review-perspectives.sh` | 観点ファイルを集める |
| `pr-create.sh` | PR を作る |
| `pr-comment.sh` | 該当行へのコメントをまとめて投稿する |
| `cleanup.sh` | マージを確認し、ワークツリーとブランチを削除し、main を最新にする |

| 初期設定用（`scripts/`） | 役割 |
|---|---|
| `setup-labels.sh` | ラベルを登録する（何度実行しても同じ結果になる） |
| `setup-project.sh` | Project を作るか既存のものに接続し、リポジトリと紐付け、Story Point の項目を追加し、列を揃え、自動追加の設定を案内する |
| `setup-repo.sh` | マージ方法の設定と、ルールセットの登録 |
| `setup-all.sh` | 上の3つを実行し、`.claude/workflow.json` と各テンプレートを作る |

## 11. 実装の順番

| 段階 | 内容 | バージョン |
|---|---|---|
| 0. 土台 | マーケットプレイスとプラグインの骨組み、`common.sh`、`config.sh`、`doctor.sh`、CI | 0.1.0 |
| 1. 初期設定 | `setup-*.sh`、`repo-setup` | 0.2.0 |
| 2. 最小のサイクル | `task-create`、`task-start`、`commit`、`pr-create`、`task-finish`、main を守るフック | 0.3.0 |
| 3. レビュー | `review`、`review-pr`、`review-perspective-add` | 0.4.0 |
| 4. まとめる | `workflow`、`task-status`、ブランチ名を警告するフック | 1.0.0 |

最初の版は段階 0〜2。このリポジトリ自体を最初の利用者にする。
