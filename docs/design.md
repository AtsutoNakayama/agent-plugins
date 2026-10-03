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
  - ワークフローは GitHub App のトークンでリリース PR・タグ・GitHub Release を作る。GITHUB_TOKEN が起こしたイベントでは新しいワークフローが動かないので、GITHUB_TOKEN で作るとリリース PR に Lint・Test が付かず、CI を通らないままリリースが出る。また、Lint・Test をルールセットの必須チェックにできない。App は PAT と違って期限の管理が要らず、PR の作者が `<App名>[bot]` になる。
    - App は Webhook なし・このアカウントだけにインストールできる設定で作り、Repository permissions は Contents・Issues・Pull requests を Read and write にする（Issues はリリース PR のラベルに要る）。インストール先はこのリポジトリだけにする。
    - リポジトリの Variables の `RELEASE_APP_ID` に App ID を、Secrets の `RELEASE_APP_PRIVATE_KEY` に App の秘密鍵（.pem の中身全体）を登録する。秘密鍵に期限はない。ワークフローは実行ごとに 1 時間で切れるトークンを作る。
    - GITHUB_TOKEN では PR を作らないので、リポジトリの設定の「Allow GitHub Actions to create and approve pull requests」は要らない。
  - ワークフローは `googleapis/release-please-action` を使わず、版を固定した release-please の CLI（`npx release-please@<版>`）を直接実行する。Action の v5 が同梱する 17.6.0 は、リリース PR の本文にコミットのフッターの `Closes #N` を `closes #N` と書き写す。GitHub はこれを Issue を閉じる紐付けとみなすので、Project の自動化「Pull request linked to issue」が、マージで閉じたばかりの Issue を In Progress に戻してしまう。17.10.4 以降は `refs #N` と書くので紐付けにならない。Action が 17.10.4 以降を同梱したら、Action に戻してもよい。
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
- **依存する Issue**：先に終わらせる Issue があれば、本文の「依存」の見出しに `#N` で書き（無ければ「なし」）、GitHub の Issue の依存関係（blocked by。GraphQL の `addBlockedBy`）にも登録する。本文は読む人のため、依存関係はボードや Issue の画面で区別するため。文章だけ（「〜の Issue の後に」）では番号が分からないので、必ず番号で書く。存在しない Issue の番号は、起票の前に止める。1回の依頼で複数の Issue を起票するときは、依存される側から順に起票し、先に起票した番号を後の Issue の依存に使う。
- **やらない Issue を閉じる**：誤って起票した Issue や、やらないことにした Issue は、`task-cancel` で not planned（重複なら duplicate）で閉じる。
  - Issue の終わり方は、完了（completed。PR のマージで閉じる）とやめた（not planned・duplicate）の2つに分ける。完了は PR が閉じ、やめたときは `task-cancel` が閉じる。`task-finish` は Issue には触れず、マージした後の手元を片付けるだけ。名前を `task-close` にしなかったのは、close は完了で閉じるときにも使う言葉で、`task-finish` と混同しやすいため。
  - 閉じる前に、理由と参照先（代わりに作業する Issue など）を `#N` でコメントする。理由が空（空白だけを含む）なら閉じない。
  - duplicate は、重複の元の Issue の番号が分かるときだけ使い、元の Issue に紐付ける（`gh issue close --duplicate-of`。gh 2.88.0 以上。古ければ何もせずに止まって更新を促し、`doctor.sh` も更新を促す。`common.sh` の `DW_GH_MIN_VERSION`）。誤って紐付けると影響が大きいので、迷うときは not planned にする。
  - Project からは外さない。後からボードで経緯を参照できるように。
  - Story Point は残す。見積もりも記録の一部で、集計する仕組みも無いので、消す理由が無い。
  - Project の自動化（Item closed）が有効なら、閉じた Issue は完了した Issue と同じく Done に移る。
  - 着手した後にやめたときは、やめた作業も片付ける。開いている PR は同じ理由をコメントしてマージせずに閉じ、リモートのブランチを削除し、手元のワークツリーとブランチを削除する（`cleanup.sh --abandon`）。マージしていない作業は消すと戻せないので、失うもの（base_branch に無いコミット・未コミットの変更・git が無視するファイル・サブモジュールのリモートに無いコミット）を確認に出す。
  - Issue → PR とリモートのブランチ → 手元の順に行う。どのスクリプトも何度実行しても同じ結果になる（同じ理由のコメントは付け直さず、同じ閉じ方で既に閉じた Issue・閉じた PR・削除したブランチは飛ばす）ので、途中で止まっても再実行で続きから進む。
- 必要なトークンのスコープ：`project`（`gh auth refresh -s project`）。

## 5. ラベル

`feat / fix / refactor / perf / test / docs / build / ci / chore` の9個。

- `ci` は CI/CD パイプラインの変更、`build` はビルドの設定・依存関係・Dockerfile の変更に使う。
- type ラベル・ブランチ名・PR のタイトル・コミットの type は、同じ type で1対1に対応させる（読み替えはしない）。
- 緊急の修正も `fix` にする（緊急の修正のための type は設けない）。GitHub Flow には緊急の修正のための別の手順が無く、違いは緊急度だけなので、type では区別しない。緊急度が必要なら type とは別のラベル（`priority: high` など）で表す。
- 破壊的変更は、type とは別の `breaking` ラベルで表す（`labels.types` には入れない。type ラベルは1つだけという決まりはそのまま）。破壊的変更はどの type にも起こりうるので、`feat!` のような type ごとのラベルは作らない。ラベル → PR のタイトル（`<type>!: …`）→ スカッシュのコミットと情報が流れるので、Issue の段階で付けておけば `!` の付け忘れがなくなる。
  - 破壊的変更とは、既存の利用者が設定やコマンドを直さないと動かなくなる変更（設定キーやプレースホルダの名前の変更、スクリプトの引数の変更・削除、スキル名の変更など）。
  - version を上げたいから付けるものではない。破壊的変更を伴わない節目（1.0.0 など）は release-please の `release-as` で上げる。
- GitHub の既定のラベルは削除する（オプションで残せる）。
- 定義は `labels.json` に置き、利用者が編集できる。

## 6. コミットと PR の書き方

- コミット：Conventional Commits（`<type>(<scope>): <要約>`）。各コミットには `Refs` を付けない。
- PR：タイトルは `<type>: <Issueのタイトル>`、本文は概要・変更点・確認方法・`Closes #N`。Issue に `breaking` ラベルがあれば、タイトルを `<type>!: <Issueのタイトル>` にし、本文の最後に `BREAKING CHANGE: <移行のしかた>` を書く（スカッシュマージでは PR の本文がコミットの本文になる）。タイトルに `!` が無い、または本文に `BREAKING CHANGE:` が無いと、スクリプトが止める（タイトルを指定しなければ、スクリプトが `!` を付けたタイトルを作る。PR が既にあるときは、その PR のタイトルと本文を確かめる）。ラベルは Issue から引き継ぐ。通常の PR として作る（下書きにしない）。
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
- `review-perspectives.sh` は観点の本文を出力せず、使う観点（名前・title・層・パス）と、止めた観点・形式の誤ったファイルの一覧を出力する。本文はサブエージェントが読む（トークン削減のため）。形式の誤ったファイルは警告して使わず（下位の層の同じ名前の観点も使わない）、レビューは止めない。
- 観点ファイルは `review-perspective-add` スキルで作れる。置く層（`~/.claude/review/` か `<repo>/.claude/review/`）はユーザーが選ぶ。同じ層の同じ名前のファイルは上書きせず、ほかの層の同じ名前の観点を置き換えるときは確認を取る。
- 独自のレビュースキルは独自の観点だけを担当する（観点ごとにサブエージェントで並行してレビューする）。一般的なバグの検出は組み込みの `/code-review` に任せる。
- 指摘は1つの一覧にまとめ、反映するものをユーザーが選ぶ。
- PR のレビューは、GitHub Actions の上で動く Claude のワークフロー（#69）に任せる。独自の観点のレビューは手元の `review` スキルで完結させ、PR へのコメントの投稿はしない。

## 8. スキル

| スキル | 内容 | 確認を取る操作 |
|---|---|---|
| `task-create` | Issue を起票し、Project に追加する | 起票（Project への追加を含む） |
| `task-start` | 自分に割り当て、In Progress に移し、ワークツリーとブランチを作る | なし（依頼で結果が決まり、割り当てと列の移動は戻せる） |
| `task-status` | 任意の列へ移す | なし（依頼で結果が決まり、列の移動は戻せる） |
| `review` | ローカルのレビューと、反映するものの選択 | なし（反映するものはユーザーが選ぶ） |
| `review-perspective-add` | 観点ファイルを作る | ほかの層の同じ名前の観点の置き換え（作るのは手元のファイルだけなので、それ以外は確認しない。置く層はユーザーが選ぶ） |
| `commit` | 規約に沿ったコミット。実装中に論理的な区切りごとに呼ぶ | なし（手元のコミットだけ） |
| `pr-create` | push と PR 作成 | push と PR の作成 |
| `task-cancel` | やらない Issue を、理由と参照先をコメントして not planned か duplicate で閉じる。着手していれば、PR を閉じ、リモートと手元のブランチ・ワークツリーを削除する | 閉じる・削除する（理由のコメントと、失う作業を含めて1回で確認する） |
| `task-finish` | ワークツリーとローカルブランチを削除し、main を最新にする（`git pull --ff-only`） | なし（作業が失われるときは `cleanup.sh` が何も消さずに止まる。git が無視するファイルを消すときだけ確認を取る） |
| `workflow` | 今の段階を判断して次の段階へ進める | 各段階のスキルに従う |
| `repo-setup` | 初期設定を対話的に実行し、設定ファイルを作る | ラベル・Project・リポジトリの設定の変更 |

- どのスキルも、依頼の内容から自動で呼ばれてよい（`disable-model-invocation` は付けない）。
- その代わり、次の操作の前には、必ず AskUserQuestion で使用者の確認を取る。確認の前に、何が起きるか（下書きや dry-run の結果）を見せる。
  - AI が決めた内容（Issue や PR の文章、Story Point の見積もり）を GitHub に残す操作
  - 取り消しにくく、スクリプトが安全を確かめていない操作（push、リポジトリの設定の変更など）
- 依頼の一言で結果が決まり、戻せる操作（割り当て、列の移動）や、失うものが無いことをスクリプトが確かめる操作（マージ済みのワークツリーとブランチの削除）は、確認せずに進めて結果を伝える。確認を挟んでも防げるものが無く、手間が増えるだけなので。
- 確認の選択肢の説明には、選ぶと実際に何が起きるか（作るもの・削除するもの・GitHub に書き込むもの）を使用者の言葉で書く。`--dry-run` などのフラグやスクリプト名といった内部の手順は書かない。例：「`--dry-run` を外して実行する」ではなく「Issue #12 を起票し、Project の Todo に追加する」。
- 確認に必要な内容（下書き・dry-run の結果・指摘の一覧）は、AskUserQuestion の前に文章で見せるだけでなく、質問の中（選択肢の preview や質問の文）にも入れる。`/remote-control` で別の端末から使うと、質問の直前の文章が画面に出ないことがあり、何を承認するのか分からないまま選ばせることになるので。preview は単一選択の質問でだけ使えるので、複数選択の質問では選択肢の説明に入れる。

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
| `doctor.sh` | 認証とスコープ、gh・`jq`・bash のバージョン、設定ファイルを確認する（gh が古ければ更新を促す） |
| `config.sh` | 5つの層を合わせた設定を出力する |
| `issue-create.sh` | 起票、ラベルの付与、Project への追加、列と Story Point の設定、依存関係（blocked by）の登録 |
| `status-set.sh` | 列を移す |
| `branch-name.sh` | ブランチ名を作り、検証する |
| `task-start.sh` | ワークツリーの作成（サブモジュールの初期化を含む）、割り当て、In Progress への移動 |
| `context.sh` | 今のブランチから Issue・PR・段階を割り出す |
| `review-perspectives.sh` | 観点ファイルを集める |
| `review-perspective-add.sh` | 観点ファイルを作る。同じ層に同じ名前のファイルがあれば上書きせずに止まり、ほかの層にあれば `--override` が無いかぎり止まる（上位の層にあり、作っても使われないときは、下位の層にあるときと別の終了コードで知らせる） |
| `pr-create.sh` | PR を作る |
| `issue-cancel.sh` | 理由をコメントし、Issue を not planned か duplicate で閉じる。`--branch` で、そのブランチの開いている PR を閉じ、リモートのブランチを削除する。理由が空、または違う理由で既に閉じていれば何もせずに止まる |
| `cleanup.sh` | マージを確認し、ワークツリーとブランチを削除し、main を最新にする。未コミットの変更や git が無視するファイルがあれば、何も消さずに止まる（無視するファイルは `--remove-ignored` で消せる）。`--abandon` では、マージの確認と main の更新を飛ばし、失うものを一覧にして削除する |

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
| 3. レビューと Issue の整理 | `review`、`review-perspective-add`、`task-cancel`（やらない Issue を閉じ、作業を片付ける） | 0.x（release-please が上げる） |
| 4. まとめる | `workflow`、`task-status`、ブランチ名を警告するフック | 1.0.0 |

最初の版は段階 0〜2。このリポジトリ自体を最初の利用者にする。

段階 2 までは version を手で上げた。0.3.0 からは release-please がリリース PR をマージするたびに上げる（§1）ので、段階 3 の version は決めない。段階 4 の最後の PR の本文に `Release-As: 1.0.0` を書いて 1.0.0 にする。
