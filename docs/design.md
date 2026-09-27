# 設計書：開発ワークフロー用プラグインと GitHub 初期設定

全リポジトリで共通に使う Claude Code のスキル群と、GitHub の初期設定スクリプトの設計。

## 1. 配布方法

- このリポジトリを **Claude Code のプラグインマーケットプレイス**にする（`.claude-plugin/marketplace.json`）。
- リポジトリは公開。リポジトリごとに異なる値（Project の番号、列名など）は設定ファイルに外出しする。
- プラグインは `dev-workflow` の1つにまとめる。レビューだけ使いたい人が出てきたら分割を検討する。
- チームに配るときは、対象リポジトリの `.claude/settings.json` に `extraKnownMarketplaces` と `enabledPlugins` を書く。
- プラグインとして入れると、プラグインのディレクトリの外にあるファイルは使えない（キャッシュにコピーされない）。スキルから呼ぶものは、初期設定用のスクリプトも含めてすべてプラグインの中に置く。

```
agent-plugins/
├── .claude-plugin/marketplace.json
├── plugins/dev-workflow/
│   ├── .claude-plugin/plugin.json
│   ├── skills/        # 各スキル
│   ├── hooks/         # ガードレール
│   ├── review/        # 共通のレビュー観点
│   └── scripts/       # スキルから呼ぶスクリプト（lib/common.sh を含む）
│       └── setup/     # リポジトリの初期設定用
└── tests/
```

### 配布の対象とバージョン

- 配布の対象は `plugins/dev-workflow/` の中だけ。外（`.github/`、`tests/`、`docs/`、`release-please-config.json` など）はこのリポジトリ専用で、利用者には届かない。
- Claude Code は plugin.json の version → marketplace.json のエントリの version → コミット SHA の順に version を決め、version が変わらないと更新を検出しない（git のタグは読まない）。version は plugin.json だけに書き、marketplace.json のエントリには書かない。
- version は [release-please](https://github.com/googleapis/release-please) が上げ、手で変えない（`.github/workflows/release-please.yml`）。
  - release-please は今の version を `.release-please-manifest.json` に持ち、リリース PR で plugin.json と同時に上げる。手で plugin.json だけを変えると食い違うので、CI で2つが同じかを確かめる。
  - ワークフローは GITHUB_TOKEN でリリース PR を作るので、リポジトリの設定（Settings → Actions → General）で「Allow GitHub Actions to create and approve pull requests」をオンにしておく（`gh api -X PUT repos/<owner>/<repo>/actions/permissions/workflow -F can_approve_pull_request_reviews=true`）。オフのままだと、リリース PR を作る段階でジョブが失敗する。
  - main へのマージごとに、ボットがリリース PR に version の変更をためる。リリース PR をマージすると、plugin.json の version が上がり、`dev-workflow-v<version>` のタグと GitHub Release（リリースノート）が作られる。CHANGELOG.md は配布物に入れないため作らない。
  - `plugins/dev-workflow/` の中を変えたコミットは、type を問わずリリースの対象にする（`changelog-sections` で全ての type を表示する）。SKILL.md の文章だけの変更も AI への指示を変えるので、利用者に届ける。外だけを変えたコミットでは version は上がらない。
  - 上げ幅は type で決まる。1.0 より前は、`feat` と破壊的変更で minor、それ以外は patch を上げる（`bump-minor-pre-major`）。
  - このリポジトリ専用の作業は `ci` / `test` / `docs` / `chore` の type を使う。
  - release-please は、コミットのメッセージを「空行の次が `feat: ` や `fix: ` などで始まる段落」で分け、それぞれを別のコミットとして読む。PR の本文はコミットの本文になるので、本文の段落を type で始めない（意図しない上げ幅になる）。
- 破壊的変更を伴わない節目（1.0.0 など）は、`plugins/dev-workflow/` の中を変える PR の本文に `Release-As: 1.0.0` の行を書いて上げる。スカッシュマージのコミットの本文は PR の本文になる（§2、`squash_merge_commit_message: PR_BODY`）ので、release-please がその行を読む。
  - release-please はメッセージの最後の段落（フッター）しか読まず、ほかの位置に書くと何も言わずに無視する。本文の最後の `Closes #N` の次の行に、空行を挟まずに書く（`Closes #N` が無いと pr-create が空行を挟んで末尾に足すので、`Release-As` だけの段落は最後にならない）。

    ```
    Closes #60
    Release-As: 1.0.0
    ```

  - 外だけを変える PR に書いても効かない（release-please はパッケージのパスの下を変えたコミットしか読まない）。
  - マージの画面でコミットの本文を書き換えるときは、この行を消さない。
  - 書き忘れてマージしたときは、マージした PR の本文に `BEGIN_COMMIT_OVERRIDE` 〜 `END_COMMIT_OVERRIDE` でタイトルと `Release-As: 1.0.0` を書き足す。次に release-please が動くと、そのコミットのメッセージとして読まれる。

## 2. ブランチ運用とマージ

- GitHub Flow：main から短命のブランチを切り、PR を経て main にマージする。既定のマージ先は main（設定で変更できる）。
- マージは **スカッシュのみ許可**。マージしたブランチは自動で削除する。
- Issue との紐付けは PR 本文の `Closes #N`。マージすると Issue が閉じ、Project の自動化で Done に移る。
- マージは人間が行う。`"allow_ai_merge": true` で AI によるマージを許可できる。

## 3. 命名

- ブランチ名：`{type}/{issue_number}-{slug}`（例：`feat/12-add-login`）。形は設定の `branch.pattern` で変えられる。使えるプレースホルダは次の3つ。
  - `{type}`：Issue の type ラベル（例：`feat`）
  - `{issue_number}`：Issue の番号（例：`12`）
  - `{slug}`：何をするかを表す英語の短い説明（例：`add-login`）
- `type` は Issue の type ラベルから決める。起票時には type ラベルを必ず1つ付ける。
- **ブランチ名とワークツリー名は `[a-z0-9-/]` のみ**。日本語は含めない。短い説明は AI が英語で考え、スクリプトが整形・検証する。整形した結果が空になる（英数字が無い）ときは、エラーで止める。
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

- **Story Point**：数値の項目。使える値はフィボナッチ数の 1, 2, 3, 5, 8, 13, 21, 34 に固定し（設定では変えられない）、スクリプトで検証する。起票時は AI が見積もりを提案し、ユーザーが確定する（空欄も可）。21 と 34 は見積もりの精度が低いので分割を提案し、それでもよければそのまま設定する。34 より大きい作業は分割する。
- **Project への自動追加**：Project に組み込みの Auto-add を使う。有効にする API は無いので、Web の画面で1回だけ手動で有効にする。`setup-project.sh` が手順を表示し、有効になったかを API で確認する。
- `task-create` は起票の後、毎回 `addProjectV2ItemById` を呼んで項目の ID を取得する。既に追加済みなら既存の項目が返るだけなので、自動追加とは重複しない。
- 必要なトークンのスコープ：`project`（`gh auth refresh -s project`）。

## 5. ラベル

`feat / fix / refactor / perf / test / docs / build / ci / chore` の9個。

- `ci` は CI/CD パイプラインの変更、`build` はビルドの設定・依存関係・Dockerfile の変更に使う。
- type ラベル・ブランチ名・PR のタイトル・コミットの type は、同じ type で1対1に対応させる（読み替えはしない）。
- 緊急の修正も `fix` にする（緊急の修正のための type は設けない）。GitHub Flow には緊急の修正のための別の手順が無く、違いは緊急度だけなので、type では区別しない。緊急度が必要なら type とは別のラベル（`priority: high` など）で表す。
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
- 観点ファイルは frontmatter に `title`（一覧に出す1行）を書き、本文にサブエージェントへの指示を書く。観点の名前はファイル名で、同じ名前なら上位の層（リポジトリ → ユーザー → プラグイン）のファイルを使う。上位の層で `enabled: false` と書くと、下位の層の観点を止められる。
- `review-perspectives.sh` は観点のパスと title だけを出力し、本文はサブエージェントが読む（トークン削減のため）。形式の誤ったファイルは警告して使わず、レビューは止めない。
- 独自のレビュースキルは独自の観点だけを担当する（観点ごとにサブエージェントで並行してレビューする）。一般的なバグの検出は組み込みの `/code-review` に任せる。
- 指摘は1つの一覧にまとめ、反映するものをユーザーが選ぶ。
- PR のレビューも同じ観点を使い、選んだ指摘を該当行へのコメントとして投稿する。

## 8. スキル

| スキル | 内容 | 確認を取る操作 |
|---|---|---|
| `task-create` | Issue を起票し、Project に追加する | 起票（Project への追加を含む） |
| `task-start` | 自分に割り当て、In Progress に移し、ワークツリーとブランチを作る | 割り当てと列の移動 |
| `task-status` | 任意の列へ移す | 列の移動 |
| `review` | ローカルのレビューと、反映するものの選択 | なし（反映するものはユーザーが選ぶ） |
| `review-pr` | PR のレビューと、該当行へのコメント投稿 | コメントの投稿 |
| `review-perspective-add` | 観点ファイルを作る | なし（手元のファイルだけ） |
| `commit` | 規約に沿ったコミット。実装中に論理的な区切りごとに呼ぶ | なし（手元のコミットだけ） |
| `pr-create` | push と PR 作成 | push と PR の作成 |
| `task-finish` | ワークツリーとローカルブランチを削除し、main を最新にする（`git pull --ff-only`） | ワークツリーとブランチの削除 |
| `workflow` | 今の段階を判断して次の段階へ進める | 各段階のスキルに従う |
| `repo-setup` | 初期設定を対話的に実行し、設定ファイルを作る | ラベル・Project・リポジトリの設定の変更 |

- どのスキルも、依頼の内容から自動で呼ばれてよい（`disable-model-invocation` は付けない）。
- その代わり、外部に影響する操作（GitHub への書き込み、push）と、取り消しにくい操作（ワークツリーやブランチの削除）の前には、必ず AskUserQuestion で使用者の確認を取る。確認の前に、何が起きるか（下書きや dry-run の結果）を見せる。

## 9. ガードレール

1. **GitHub のルールセット**（`setup-repo.sh`）：main への直接 push の禁止と PR の必須化、強制 push と main の削除の禁止。承認の必須化はオプション（既定は無効）。
2. **Claude Code のフック**（`hooks/guard-git.sh`）：main 上での commit と、main への push をブロックする。強制 push（`--force` / `-f` / `+<refspec>` / `--mirror`）をブロックする（`--force-with-lease` は許可）。ブランチ名が規約に合わないときは警告する。
3. **`workflow` スキル**：着手 → 実装（論理的な区切りごとにコミット）→ ローカルレビュー → PR → PR レビュー → マージ（人間）→ 後片付け。

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
| `task-start.sh` | ワークツリーの作成（サブモジュールの初期化を含む）、割り当て、In Progress への移動 |
| `context.sh` | 今のブランチから Issue・PR・段階を割り出す |
| `review-perspectives.sh` | 観点ファイルを集める |
| `pr-create.sh` | PR を作る |
| `pr-comment.sh` | 該当行へのコメントをまとめて投稿する |
| `cleanup.sh` | マージを確認し、ワークツリーとブランチを削除し、main を最新にする |

| 初期設定用（`plugins/dev-workflow/scripts/setup/`） | 役割 |
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
| 3. レビュー | `review`、`review-pr`、`review-perspective-add` | 0.x（release-please が上げる） |
| 4. まとめる | `workflow`、`task-status`、ブランチ名を警告するフック | 1.0.0 |

最初の版は段階 0〜2。このリポジトリ自体を最初の利用者にする。

段階 2 までは version を手で上げた。0.3.0 からは release-please がリリース PR をマージするたびに上げる（§1）ので、段階 3 の version は決めない。段階 4 の最後の PR の本文に `Release-As: 1.0.0` を書いて 1.0.0 にする。
