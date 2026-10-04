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
| `/dev-workflow:task-create` | 依頼の内容から Issue を起票し、type ラベル（破壊的変更なら `breaking` ラベルも）を付けて Project に追加する。Story Point は見積もりを提案し、確認してから設定する。先に終わらせる Issue があれば、本文の「依存」に `#N` を書き、GitHub の依存関係（blocked by）にも登録する。大きな仕様を分けた一部なら、仕様の Issue を親にしてサブ Issue として紐付ける（親子は2層が目安で、必要なら3層まで。Story Point は子にだけ付ける）。親と子をまとめて下書きし、親子の木を見せて確認してから、親 → 子の順に起票できる。既にある Issue を親に指定して、その下に子を足すこともできる |
| `/dev-workflow:task-start` | Issue の作業を始める。ブランチとワークツリー（`.claude/worktrees/<ブランチ名>`）を作り、自分に割り当てて In Progress に移す。確認を取らずに進め、結果を伝える |
| `/dev-workflow:task-status` | Issue を Project の指定した列へ移す。`Blocked` など自分で足した列へも移せる。Project に入っていなければ追加してから移す。確認を取らずに進め、結果を伝える。Project に無い列を指定したときは、移さずに列の一覧を見せる |
| `/dev-workflow:commit` | 変更を Conventional Commits の規約に沿ってコミットする。メッセージを検証してからコミットし、main の上ではコミットしない |
| `/dev-workflow:review` | 作業中のブランチの変更を、組み込みの `/code-review` と独自のレビューの観点（下記）で並行してレビューし、指摘を1つの一覧にまとめる。反映する指摘を選ぶと、それだけを直してコミットする |
| `/dev-workflow:review-perspective-add` | レビューの観点を聞き取り、形式に沿った観点ファイル（下記）を自分の層（`~/.claude/dev-workflow/review/`）かリポジトリの層（`<repo>/.claude/dev-workflow/review/`）に作る。同じ層に同じ名前の観点があれば上書きせずに知らせ、ほかの層の観点を置き換えるときは確認する |
| `/dev-workflow:adr-create` | 設計上の判断を、MADR 4.0.0 の書式の ADR として `docs/adr/<Issue 番号を6桁に0埋め>-<名前>.md` に残す（[ADR](#adr)）。判断の内容を聞き取り、判断に合うテンプレートを選んで中身まで書く。古い ADR を置き換えるときは、古い方の status だけを superseded にする。確認は取らない（作るのは手元のファイルだけ） |
| `/dev-workflow:pr-create` | 作業用のブランチを push し、Issue に紐付けた PR を作る。タイトルは `<type>: <Issueのタイトル>`、本文は PR テンプレートに沿って書き、`Closes #N` を付けてラベルを引き継ぐ。Issue に `breaking` ラベルがあれば、タイトルを `<type>!:` にし、本文に `BREAKING CHANGE:`（移行のしかた）を書く。確認してから push する |
| `/dev-workflow:task-finish` | PR がマージされた後の後片付け。マージを確かめ、ワークツリーとローカルのブランチを削除し、main を最新にする（`git pull --ff-only`）。確認を取らずに進め、作業が失われるとき（マージされていない、PR に入っていないコミット・未コミットの変更・サブモジュールの push していないコミットがある）は、何も消さずに止まる。`.env` など git が無視するファイルが残っているときは、一覧を見せて消してよいか確認する |
| `/dev-workflow:task-cancel` | やらないことにした Issue や誤って起票した Issue を取りやめる。理由と参照先（代わりに作業する Issue など）をコメントに書き、not planned（重複なら元の Issue に紐付けて duplicate）で閉じる。着手していれば、PR を閉じ、リモートと手元のブランチ・ワークツリーも削除する。失う作業（マージしていないコミット・未コミットの変更・`.env` など）を見せて確認してから行う。Project からは外さず、Story Point も残す（後からボードで経緯を参照できるように）。マージした後の片付けは `task-finish` を使う |

Issue の番号を取るスキル（`task-start`・`task-status`・`task-finish`・`task-cancel`）は、`/dev-workflow:task-start 12` や `/dev-workflow:task-start #12` のように、引数で番号を渡せます。`task-status` は `/dev-workflow:task-status 12 Blocked` のように、番号、列名の順に渡します。引数が無ければ、依頼の文章から読み取ります。

## レビューの観点

`/dev-workflow:review` は、次の3つの層に置いた観点ファイル（1ファイルに1観点の Markdown）を合わせて使います。同じ名前の観点があれば、上の層のファイルが使われます。

1. `<repo>/.claude/dev-workflow/review/*.md`：リポジトリの観点（チームで共有する）
2. `~/.claude/dev-workflow/review/*.md`：自分の観点（全リポジトリで使う）
3. `plugins/dev-workflow/review/*.md`：プラグインに同梱する共通の観点

```markdown
---
title: 一覧に出す1行の説明（必須）
types: [fix]
paths: ["**/*.sh"]
issue: required
base_ahead: required
---

サブエージェントへのレビューの指示。何を確かめ、どう指摘するかを書く。
```

- 観点ファイルは `/dev-workflow:review-perspective-add` で作れます（手で書いても構いません）。
- レビューの観点の追加・修正は、そのきっかけになったタスクの PR に含め、別の Issue にはしません。`/dev-workflow:review-perspective-add` は、リポジトリの層の観点を今のタスクのワークツリーに作ります。同梱の観点 `issue-requirements` は、観点の追加・修正を範囲外の変更として指摘しません。
- 観点の名前はファイル名（`.md` を除く）です。小文字の英数字と `-` だけを使います。
- `title` 以外の `types`・`paths`・`issue`・`base_ahead` は、実行する条件です（任意。上の例はすべて書いたものです）。書くと、当てはまらない変更ではその観点を実行しません（サブエージェントを起動しないので、そのぶん速く安くなります）。書かなければ毎回実行し、複数書けばすべてに当てはまるときだけ実行します。`types` は Issue の type ラベル（Issue が無いか1つに決まらなければブランチ名の type）で判断し、type が分からなければその観点は実行しません。`paths` は `.gitignore` や GitHub Actions の `paths` と同じ書き方です（`*` は `/` をまたがず、`**/*.sh` でどこの `.sh` にも当たります。`!` で始めると除外で、`["!docs/**"]` は docs の下だけを変えたときは実行しません）。外した観点とその理由は、レビューの結果で伝えます。
- 一覧の各指摘には、なぜ起きたかと、その場所だけの誤り（局所）か設計や前提の誤り（構造）かが添えられます。構造の指摘には、根本を直す案も並びます。
- 反映でコードの振る舞いが変わると（言い換えやコメントだけなら除く）、反映したコミットの差分を再レビューします。新しい指摘が無ければ終わります。周回の上限は設定の `review.max_rounds`（既定 3、最初のレビューを含む）です。上限の周でも指摘が出ると（何も反映しなかったときも）、もう1周するか終えるかを聞かれ、続ければ4周目以降も回せます。上限で終えた後も、「もう一度レビューして」でいつでも実行できます。
- 反映した直しの再レビューで、前の周と同じ場所や同じ種類の指摘が合わせて2回以上出ると「繰り返し」と印が付き、根本の原因とそれを直す案が示されます（その場所だけを直す案では済ませません）。
- 組み込みの `/code-review` も、同梱の観点 `code-review`（`builtin: code-review`）として扱います。止めたり条件を付けたりするのは、ほかの観点と同じです。
- 同梱の観点を使わないときは、上の層に同じ名前のファイルを置き、frontmatter に `enabled: false` と書きます（本文と `title` は省けます）。
- 使われる観点は `plugins/dev-workflow/scripts/review-perspectives.sh` で確かめられます。引数なしでは、層を合わせた観点の一覧（条件で外す前）が出ます。今の変更で使われる観点を見るには、`--auto` を付けます（review スキルと同じく、基点・マージ先・Issue・type をブランチから決め、`context` に出します。設定の `review.max_rounds` が1以上の整数でなければ止まります）。形式の誤ったファイルは警告を出して使いません。そのファイルと同じ名前の観点は、下の層にあっても使いません（`enabled: false` の書き間違いで、止めたつもりの観点が動かないようにするため）。

同梱の観点：

| 観点 | 内容 |
|---|---|
| `issue-requirements` | 変更が Issue の「やること」と「完了条件」を満たし、範囲外の変更が混ざっていないか（Issue があるときだけ） |
| `docs-sync` | 振る舞いの変更に合わせて、ドキュメントとコメントが直されているか |
| `regression-test` | 不具合の修正に、その不具合がもう一度起きないことを確かめるテストがあるか（type が `fix` のときだけ） |
| `main-drift` | ブランチを作った後にマージ先に入った変更と、このブランチの変更が食い違っていないか（マージ先が進んでいるときだけ） |
| `code-review` | 一般的なバグ。サブエージェントの代わりに、組み込みの `/code-review` を実行する |

## ADR

`/dev-workflow:adr-create` は、設計上の判断の「なぜ」を ADR（Architecture Decision Record）として残します。

- 書式は [MADR](https://github.com/adr/madr) 4.0.0 です。公式の4つのテンプレートを日本語に訳して、プラグインに同梱しています（`plugins/dev-workflow/templates/adr/`。元にした版とライセンスは同じ場所の `README.md`）。
- ADR は Issue ごとではなく、判断ごとに作ります。判断をした Issue でだけ作り、1つの Issue から2つ以上の ADR ができてもかまいません。
- ファイル名は `docs/adr/<Issue 番号を6桁に0埋め>-<短い名前>.md` です（例：`docs/adr/000107-use-madr.md`）。連番ではなく Issue 番号なので、ワークツリーで並行して作業しても名前がぶつかりません。
- テンプレートは判断に合わせて選びます。他の案と比べて選んだ判断・破壊的変更・元に戻しにくい判断は全部の節がある `adr-template.md`、記録しておけば足りる判断は `adr-template-minimal.md` です。説明のない2つ（`bare`）は、手で書く人向けです。
- 置き換えた ADR は書き換えません。古い方の `status` の行だけを `superseded by <新しい ADR>` にします。
- 置き場所は、設定（`.claude/dev-workflow/config.json`）の `adr.dir` で変えられます（既定は `docs/adr`。リポジトリのルートからの相対パス）。

```json
{ "adr": { "dir": "doc/decisions" } }
```

## フック

### タスクの進め方

プラグインを入れると、セッションの始まり（起動・`/resume`・`/clear`・コンパクトの後）のたびに、タスクの進め方（Issue から始める → 着手 → 区切りごとのコミット → PR の前のローカルレビュー → PR → 後片付け、と取りやめ）と、それぞれで使うスキルを Claude に読み込ませます（`hooks/task-flow.sh`）。スキルは呼ばれたときにしか読み込まれないので、流れはいつも渡しておきます。会話が要約されても抜けません。

既定の流れは `plugins/dev-workflow/defaults/task-flow.md` です。次のファイルを置くと、既定の流れのあとに、この順で追記として渡します（後ろほど優先します）。

1. `~/.claude/dev-workflow/task-flow.md`：自分の追記（全リポジトリで使う）
2. `<repo>/.claude/dev-workflow/task-flow.md`：リポジトリの追記（チームで共有する）

渡すのは合わせて 1 万文字までです。超えた分は切り、読み直すファイルを Claude に知らせます。

### git の操作を守る

プラグインを入れると、Claude Code が Bash で次の git の操作をしようとしたときに止めます（`hooks/guard-git.sh`）。守るブランチは設定の `base_branch`（既定は main）です。

- base_branch の上での `git commit`
- base_branch への `git push`（base_branch の上で push 先を書かずに push するときを含む）
- 強制 push（`--force` / `-f` / `+<refspec>` / `--mirror`）。`--force-with-lease` は許可する

また、規約（`branch.pattern`）に合わない名前でブランチを作ろうとしたとき（`git switch -c` / `git checkout -b` / `git branch <名前>` / `git worktree add -b`）は、コマンドは止めずに、使用者と Claude に警告します。

`cd` や `git -C` で移った先のリポジトリ・ブランチで判断します。コマンドの文字列を簡易に解析するだけなので、`sh -c` や git の別名を通すと見逃します。最後の守りは GitHub のルールセット（下記）です。

## リポジトリの初期設定

Claude Code で `/dev-workflow:repo-setup` を実行すると、選択肢を聞き、予定を見せてから、以下をまとめて行います。スクリプトを直接実行することもできます。

`gh` に `project` スコープが必要です（`gh auth refresh -h github.com -s project` を普通のターミナルで実行）。

### まとめて行う

```bash
# ラベル・Project・マージ方法とルールセット・PR / Issue テンプレートを揃える（対象のリポジトリの中で実行）
plugins/dev-workflow/scripts/setup/setup-all.sh --dry-run
plugins/dev-workflow/scripts/setup/setup-all.sh
```

作ったファイル（テンプレート、`.claude/dev-workflow/config.json`）はコミットされません。main は守られるので、PR でマージしてください。

### ラベル

```bash
# type ラベル（feat / fix など）と breaking ラベルを作成・更新し、GitHub の既定のラベルを削除する
plugins/dev-workflow/scripts/setup/setup-labels.sh

# 既定のラベルを残す・変更せずに予定だけを確認する
plugins/dev-workflow/scripts/setup/setup-labels.sh --keep-defaults
plugins/dev-workflow/scripts/setup/setup-labels.sh --dry-run
```

定義は `plugins/dev-workflow/defaults/labels.json`。リポジトリに `.claude/dev-workflow/labels.json` を置くとそちらを使います（`--file` でも指定できます）。`--repo` で別のリポジトリを指定したときは、そのリポジトリの既定のブランチにある `.claude/dev-workflow/labels.json` を読みます。独自の `.claude/dev-workflow/labels.json` には `breaking` ラベルも定義してください（無いと破壊的変更の Issue を起票できないので、警告を出します）。

削除するのは、GitHub が新しいリポジトリに作る既定のラベル（`accessibility`・`bug`・`enhancement` など）のうち、定義に無いものだけです。既定のラベルを残したいときは、そのラベルを定義に書くか、`--keep-defaults` ですべて残してください。

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

#### マージの前に CI を求める

別の PR が先にマージされて main が進んでも、前の PR の CI の結果は古いままです。単独では通る2つの PR が組み合わさって main が壊れることがあるので、チェックの成功と、PR が最新の main を取り込んでいることを、ルールセットで求められます。

```bash
# lint-result と test-result の成功と、最新の main の取り込みを、マージの条件にする
plugins/dev-workflow/scripts/setup/setup-repo.sh --required-check lint-result --required-check test-result
```

- `--required-check` は、`setup-all.sh` にも渡せます。繰り返し指定できます。
- 指定した名前の一覧で、必須のチェックを置き換えます。CI を足したり外したりしたときは、新しい一覧で実行し直します。付けなければ、ルールセットの必須のチェックには触れません。GitHub の設定画面で直した必須のチェックも、そのまま残ります。
- チェックの名前は、チームの CI で決まるので、プラグインは決めません。CI が無いリポジトリや、まだ報告されたことのない名前を指定すると、チェックが「待ち」のまま残ってマージできなくなります。名前は、そのチェックが一度動いてから指定してください。
- 名前は、CI 全体の結果を1つにまとめる「門番のジョブ」にすることをおすすめします。ジョブを足しても、必須の名前は変わらずに済みます。ジョブごとに必須にすると、CI の変更のたびにこのコマンドを実行し直すことになります。
- `paths-ignore` などでワークフローが動かない PR（ドキュメントだけの変更など）は、そのチェックが報告されず、「待ち」のままマージできなくなります。`paths-ignore` はやめ、変更の範囲を見て重いジョブを `if` で飛ばしたうえで、門番のジョブは必ず動かして成功にしてください（このリポジトリの `.github/workflows/lint.yml`・`test.yml` が例です）。

## 開発

開発に参加するときの環境の準備・開発の流れ・テストは [CONTRIBUTING.md](CONTRIBUTING.md) を参照してください。
