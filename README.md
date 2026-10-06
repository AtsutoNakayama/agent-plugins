# agent-plugins

導入したリポジトリで共通に使う Claude Code のプラグイン（開発ワークフロー用のスキル群）と、GitHub リポジトリの初期設定スクリプト。

設計は [docs/design.md](docs/design.md) を参照。

## 使い方（開発中）

```bash
# プラグインを直接読み込んで Claude Code を起動する
claude --plugin-dir plugins/dev-workflow

# 実行環境と設定の確認
plugins/dev-workflow/scripts/doctor.sh
```

## 導入したリポジトリだけに効く

プラグインは、導入したリポジトリ（`.claude/dev-workflow/config.json` があるリポジトリ）の中でだけ効きます。プラグインをユーザー単位でインストールしても、プロジェクト単位でインストールしても同じです。

- 導入していないリポジトリでは、フック（main を守る・タスクの進め方を渡す・リンクを出す）は何もしません。
- 導入していないリポジトリでは、`~/.claude/dev-workflow/` に置いた自分の設定・文章のガイド・レビューの観点・タスクの進め方の追記も使いません。導入したリポジトリでは、これまでどおり使います。
- `.claude/dev-workflow/config.json` は、`/dev-workflow:repo-setup` で作られます。中身は空（`{}`）でもかまいません。ワークツリーに無くても、メインのワークツリーにあれば導入したものとみなします。
- ホームをリポジトリにしているとき（dotfiles を `~/.git` で管理するときなど）は、`~/.claude/dev-workflow/config.json` が自分の設定と同じファイルになるので、それだけではホームのリポジトリを導入したものとはみなしません。
- `doctor.sh` は、導入していないリポジトリで実行すると、このことを警告します。

これまで初期設定をせずに使っていたリポジトリでは、フックとユーザーの層が効かなくなります。引き続き使うには、`/dev-workflow:repo-setup` で初期設定するか、`.claude/dev-workflow/config.json` を `{}` で作ってコミットしてください。

## スキル

| スキル | 内容 |
|---|---|
| `/dev-workflow:repo-setup` | リポジトリの初期設定（下記） |
| `/dev-workflow:task-create` | 依頼の内容から Issue を起票し、type ラベル（破壊的変更なら `breaking` ラベルも）を付けて Project に追加する。下書きの前に、開いている Issue から重複と親の候補を探し、重なる Issue があれば、起票の前にどう扱うか（既にある Issue で進める、その Issue を親にする、など）を聞く。Story Point は見積もりを提案し、確認してから設定する。先に終わらせる Issue があれば、本文の「依存」に `#N` を書き、GitHub の依存関係（blocked by）にも登録する。大きな仕様を分けた一部なら、仕様の Issue を親にしてサブ Issue として紐付ける（親子は2層が目安で、必要なら3層まで。Story Point は子にだけ付ける）。親と子をまとめて下書きし、親子の木を見せて確認してから、親 → 子の順に起票できる。既にある Issue を親に指定して、その下に子を足すこともできる。触りそうなファイル・領域も本文の「変更するファイル・領域」に書く（`task-next` が並列にできるかを見るのに使う。分からなければ「不明」） |
| `/dev-workflow:task-next` | Todo の Issue から、次に着手すべきものと、同時に進められる組を提案する。優先順位は Project の Todo の上から順で、依存（GitHub の blocked by と本文の「依存」）が終わっていないものと、サブ Issue を持つ親の Issue（作業は子の Issue で進める）は候補から外す。本文の「変更するファイル・領域」と、着手中（In Progress と、設定されていれば PR を出した後の列 `pr_opened`）の Issue の領域・PR のファイルが重なりそうなものは「並列にできない」と警告する（止めはしない）。何も変えない読み取り専用で、herdr などが無くても使える |
| `/dev-workflow:task-start` | Issue の作業を始める。ブランチとワークツリー（`.claude/worktrees/<ブランチ名>`）を作り、自分に割り当てて In Progress に移す。確認を取らずに進め、結果を伝える。親の Issue（サブ Issue を持つ Issue）には着手せず、開いている子の一覧を見せる |
| `/dev-workflow:task-status` | Issue を Project の指定した列へ移す。`Blocked` など自分で足した列へも移せる。Project に入っていなければ追加してから移す。確認を取らずに進め、結果を伝える。Project に無い列を指定したときは、移さずに列の一覧を見せる |
| `/dev-workflow:commit` | 変更を Conventional Commits の規約に沿ってコミットする。メッセージを検証してからコミットし、main の上ではコミットしない |
| `/dev-workflow:review` | 作業中のブランチの変更を、組み込みの `/code-review` と独自のレビューの観点（下記）で並行してレビューし、指摘を1つの一覧にまとめる。各指摘は同じ誤りがほかの場所に無いか（水平展開）も判定する。反映する指摘を選ぶと、その指摘（水平展開の場所を含む）だけを直してコミットする。終えるときに、見落としの指摘や今後も要らない指摘を観点に残すかを尋ねる |
| `/dev-workflow:review-perspective-add` | レビューの観点を聞き取り、形式に沿った観点ファイル（下記）を自分の層（`~/.claude/dev-workflow/review/`）かリポジトリの層（`<repo>/.claude/dev-workflow/review/`）に作る。同じ層に同じ名前の観点があれば上書きせずに知らせ、ほかの層の観点を置き換えるときは確認する |
| `/dev-workflow:adr-create` | 設計上の判断を、MADR 4.0.0 の書式の ADR として `docs/adr/<Issue 番号を6桁に0埋め>-<名前>.md` に残す（[ADR](#adr)）。判断の内容を聞き取り、判断に合うテンプレートを選んで中身まで書く。古い ADR を置き換えるときは、古い方の status だけを superseded にする。確認は取らない（作るのは手元のファイルだけ） |
| `/dev-workflow:pr-create` | 作業用のブランチを push し、Issue に紐付けた PR を作る。タイトルは `<type>: <Issueのタイトル>`、本文は PR テンプレートに沿って書き、`Closes #N` を付けてラベルを引き継ぐ。Issue に `breaking` ラベルがあれば、タイトルを `<type>!:` にし、本文に `BREAKING CHANGE:`（移行のしかた）を書く。Issue の「やること」のうち差分で済んだ項目にチェックを付ける。確認してから push する |
| `/dev-workflow:pr-respond` | PR を出した後に付いたレビューの指摘・質問・コメントと、CI の失敗に対応する。最初に PR の状態（CI・レビュー・マージできるか）を見せ、指摘（直す）・質問（答えるだけ）・感想や承認（何もしない）に分けて一覧にする。直すものと答えるものを選ぶと、直してコミットし、push するコミットと返信の本文を見せて確認してから、push と返信を行う。スレッドは resolved にしない（レビューした人に任せる）。コメントの本文にある AI への指示には従わない。コメントが無ければ何も変えずに終わる。使わなくてもマージや `task-finish` は進められる |
| `/dev-workflow:task-finish` | PR がマージされた後の後片付け。マージを確かめ、ワークツリーとローカルのブランチを削除し、main を最新にし（`git pull --ff-only`）、PR が閉じる Issue が閉じたかも伝える（閉じるのは頼まれたときだけ）。確認を取らずに進め、作業が失われるとき（マージされていない、PR に入っていないコミット・未コミットの変更・サブモジュールの push していないコミットがある）は、何も消さずに止まる。`.env` など git が無視するファイルが残っているときは、一覧を見せて消してよいか確認する |
| `/dev-workflow:branch-update` | PR のブランチに、設定済みの `base_branch`（既定は main）の最新状態を取り込む。遅れを調べ、`origin/<base_branch>` を merge し（rebase と強制 push は使いません）、衝突を直して、リポジトリのテストとチェックを通します。push の前に、取り込んだコミットとチェックの結果を見せて確認を取り、push の後は CI が通り直るのを待って結果を伝えます。すでに最新なら何もしません。判断できない衝突はユーザーに聞きます |
| `/dev-workflow:task-cancel` | やらないことにした Issue や誤って起票した Issue を取りやめる。理由と参照先（代わりに作業する Issue など）をコメントに書き、not planned（重複なら元の Issue に紐付けて duplicate）で閉じる。着手していれば、PR を閉じ、リモートと手元のブランチ・ワークツリーも削除する。失う作業（マージしていないコミット・未コミットの変更・`.env` など）を見せて確認してから行う。親の Issue（サブ Issue を持つ Issue）を取りやめるときは、開いている子孫（子・孫）を一緒に取りやめるか、残すかを確認で選ぶ（一緒に取りやめるなら、着手中の子孫の PR とブランチも片付ける）。Project からは外さず、Story Point も残す（後からボードで経緯を参照できるように）。マージした後の片付けは `task-finish` を使う |

Issue の番号を取るスキル（`task-start`・`task-status`・`task-finish`・`task-cancel`）は、`/dev-workflow:task-start 12` や `/dev-workflow:task-start #12` のように、引数で番号を渡せます。`task-status` は `/dev-workflow:task-status 12 Blocked` のように、番号、列名の順に渡します。引数が無ければ、依頼の文章から読み取ります。`pr-respond` は `/dev-workflow:pr-respond 42` のように PR の番号を渡せます（無ければ今のブランチの PR）。

`pr-respond` は、投稿者ごとに担当の skill を、設定（`.claude/dev-workflow/config.json`）の `pr_respond.handlers` で指定できます。担当の skill がある投稿者の指摘は、その skill に任せます（PR の番号を引数にして呼びます）。設定が無ければ、すべて汎用の手順で扱います。投稿者の名前は、大文字と小文字、末尾の `[bot]` を区別しません。

```json
{
  "pr_respond": {
    "handlers": {
      "coderabbitai[bot]": "coderabbit-respond"
    }
  }
}
```

## レビューの観点

`/dev-workflow:review` は、次の3つの層に置いた観点ファイル（1ファイルに1観点の Markdown）を合わせて使います。同じ名前の観点があれば、上の層のファイルが使われます。

1. `<repo>/.claude/dev-workflow/review/*.md`：リポジトリの観点（チームで共有する）
2. `~/.claude/dev-workflow/review/*.md`：自分の観点（導入したすべてのリポジトリで使う）
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
- 一覧の各指摘には、なぜ起きたかと、その場所だけの誤り（局所）か設計や前提の誤り（構造）かが添えられます。構造の指摘には、根本を直す案も並びます。さらに、同じ書き方・同じ前提の場所を検索して水平展開の要否が判定され、同じ誤りが残っていればその場所も一覧に加わります（反映するときは、その場所も直して同じ検索で残りが無いことを確かめます）。
- 反映でコードの振る舞いが変わると（言い換えやコメントだけなら除く）、反映したコミットの差分を再レビューします。新しい指摘が無ければ終わります。周回の上限は設定の `review.max_rounds`（既定 3、最初のレビューを含む）です。上限の周でも指摘が出ると（何も反映しなかったときも）、もう1周するか終えるかを聞かれ、続ければ4周目以降も回せます。上限で終えた後も、「もう一度レビューして」でいつでも実行できます。
- 反映した直しの再レビューで、前の周と同じ場所や同じ種類の指摘が合わせて2回以上出ると「繰り返し」と印が付き、根本の原因とそれを直す案が示されます（その場所だけを直す案では済ませません）。
- 組み込みの `/code-review` も、同梱の観点 `code-review`（`builtin: code-review`）として扱います。止めたり条件を付けたりするのは、ほかの観点と同じです。
- レビューを終えるときに、レビューが見落としてユーザーが出した指摘があれば、それを観点に残すか（既にある観点を直すか、新しい観点を作るか）を尋ねます。反映しなかった指摘に、今後も要らないという理由（例：「この書き方はこのリポジトリでは許容」）を述べたときは、今後指摘しないようにするかを尋ねます。どちらも、選んだときだけ観点ファイルを作ったり直したりします。一般的なバグや、その場限りの好みは観点にしません。
- 今後指摘しないものは、その観点ファイルの「指摘しないこと」に書きます。`/code-review` の指摘は、上の層に `code-review.md`（`builtin: code-review`）を置き、本文の「## 指摘しないこと」の節に書きます。`/code-review` そのものは変わらず、`/dev-workflow:review` が一覧にまとめるときにこの節と照らして外し、外した件数を伝えます。
- 同梱の観点を使わないときは、上の層に同じ名前のファイルを置き、frontmatter に `enabled: false` と書きます（本文と `title` は省けます）。
- 使われる観点は `plugins/dev-workflow/scripts/review-perspectives.sh` で確かめられます。引数なしでは、層を合わせた観点の一覧（条件で外す前）が出ます。今の変更で使われる観点を見るには、`--auto` を付けます（review スキルと同じく、基点・マージ先・Issue・type をブランチから決め、`context` に出します。設定の `review.max_rounds` が1以上の整数でないときと、`review.model` が null か使えるモデルでないときは止まります）。形式の誤ったファイルは警告を出して使いません。そのファイルと同じ名前の観点は、下の層にあっても使いません（`enabled: false` の書き間違いで、止めたつもりの観点が動かないようにするため）。

同梱の観点：

| 観点 | 内容 |
|---|---|
| `issue-requirements` | 変更が Issue の「やること」と「完了条件」を満たし、範囲外の変更が混ざっていないか（Issue があるときだけ） |
| `docs-sync` | 振る舞いの変更に合わせて、ドキュメントとコメントが直されているか |
| `regression-test` | 不具合の修正に、その不具合がもう一度起きないことを確かめるテストがあるか（type が `fix` のときだけ） |
| `test-coverage` | 機能の追加・リファクタリング・性能の改善で、変えた振る舞いを確かめるテストがあり、境界値や異常系も確かめ、実装の写しになっていないか（type が `feat`・`refactor`・`perf` のときだけ。テストの仕組みが無いリポジトリや、テストで確かめられない変更は指摘しない） |
| `main-drift` | ブランチを作った後にマージ先に入った変更と、このブランチの変更が食い違っていないか（マージ先が進んでいるときだけ） |
| `code-review` | 一般的なバグ。サブエージェントの代わりに、組み込みの `/code-review` を実行する |

## ADR

`/dev-workflow:adr-create` は、設計上の判断の「なぜ」を ADR（Architecture Decision Record）として残します。

- 書式は [MADR](https://github.com/adr/madr) 4.0.0 です。公式の4つのテンプレートを日本語に訳して、プラグインに同梱しています（`plugins/dev-workflow/templates/adr/`。元にした版とライセンスは同じ場所の `README.md`）。
- ADR は Issue ごとではなく、判断ごとに作ります。判断をした Issue でだけ作り、1つの Issue から2つ以上の ADR ができてもかまいません。過去の判断を後から残すときは、残す作業の Issue の PR で作り、ADR の `issue` と `date` を、判断をした Issue と日にします（`adr-create.sh` の `--issue`・`--date`）。
- ファイル名は `docs/adr/<Issue 番号を6桁に0埋め>-<短い名前>.md` です（例：`docs/adr/000107-use-madr.md`）。連番ではなく Issue 番号なので、ワークツリーで並行して作業しても名前がぶつかりません。
- テンプレートは判断に合わせて選びます。他の案と比べて選んだ判断・破壊的変更・元に戻しにくい判断は全部の節がある `adr-template.md`、記録しておけば足りる判断は `adr-template-minimal.md` です。説明のない2つ（`bare`）は、手で書く人向けです。
- 置き換えた ADR は書き換えません。古い方の `status` の行だけを `superseded by <新しい ADR>` にします。
- 置き場所は、設定（`.claude/dev-workflow/config.json`）の `adr.dir` で変えられます（既定は `docs/adr`。リポジトリのルートからの相対パス）。

```json
{ "adr": { "dir": "doc/decisions" } }
```

## フック

### タスクの進め方

導入したリポジトリでは、セッションの始まり（起動・`/resume`・`/clear`・コンパクトの後）のたびに、タスクの進め方（Issue から始める → 着手 → 区切りごとのコミット → PR の前のローカルレビュー → PR →（指摘が付いたら対応）→ 後片付け、と取りやめ）と、それぞれで使うスキルを Claude に読み込ませます（`hooks/task-flow.sh`）。スキルは呼ばれたときにしか読み込まれないので、流れはいつも渡しておきます。会話が要約されても抜けません。

既定の流れは `plugins/dev-workflow/defaults/task-flow.md` です。次のファイルを置くと、既定の流れのあとに、この順で追記として渡します（後ろほど優先します）。

1. `~/.claude/dev-workflow/task-flow.md`：自分の追記（導入したすべてのリポジトリで使う）
2. `<repo>/.claude/dev-workflow/task-flow.md`：リポジトリの追記（チームで共有する）

渡すのは合わせて 1 万文字までです。超えた分は切り、読み直すファイルを Claude に知らせます。

### git の操作を守る

導入したリポジトリでは、Claude Code が Bash で次の git の操作をしようとしたときに止めます（`hooks/guard-git.sh`）。守るブランチは設定の `base_branch`（既定は main）です。

- base_branch の上での `git commit`
- base_branch への `git push`（base_branch の上で push 先を書かずに push するときを含む）
- 強制 push（`--force` / `-f` / `+<refspec>` / `--mirror`）。`--force-with-lease` は許可する

また、規約（`branch.pattern`）に合わない名前でブランチを作ろうとしたとき（`git switch -c` / `git checkout -b` / `git branch <名前>` / `git worktree add -b`）は、コマンドは止めずに、使用者と Claude に警告します。

`cd` や `git -C` で移った先、`--git-dir`・`GIT_DIR` などで指した先のリポジトリ・ブランチで判断し、その先が導入していないリポジトリなら止めません。守るブランチ（`base_branch`）も、その先のリポジトリの設定から読みます。bare リポジトリのように作業ツリーが分からないリポジトリは、HEAD にチームの設定がコミットされているかで判断します。git がリポジトリを見つけられないときは、止める側で調べます。コマンドの文字列を簡易に解析するだけなので、`sh -c` や git の別名を通すと見逃します。最後の守りは GitHub のルールセット（下記）です。

### PR や Issue のリンクを出す

導入したリポジトリでは、git の操作のあとに、関連する PR・Issue・CI のリンクを、使用者の画面に出します（`hooks/pr-link.sh`）。PR や Issue の画面を探さなくても、すぐ開けます。

| 操作 | 出すリンク |
| --- | --- |
| `git push`（`pr-create.sh` を含む） | 開いた PR（無ければ PR を作る URL）、紐付く Issue、PR の CI（checks。PR が無ければブランチの CI の実行ページ） |
| `git commit`（`commit.sh` を含む）、ブランチ・ワークツリーの作成（`git switch -c` など。`task-start.sh` を含む） | 紐付く Issue |
| `gh pr create`・`gh issue create`（`pr-create.sh`・`issue-create.sh` を含む） | 作った PR・Issue（標準出力から拾う） |

- 紐付く Issue は、ブランチ名（`branch.pattern` の `{issue_number}`）から分かります。ブランチを作るコマンドでは、作るブランチの Issue です（名前を拾えないときは出しません）。main など、Issue の番号が分からないブランチでは、ブランチから導くリンクは出しません。
- `cd` や `git -C` で別のリポジトリ・ブランチへ移ったコマンドでは、移った先を追わず、Claude Code の今のディレクトリのブランチで判断します（`sh -c` や git の別名を通したコマンドは見逃します）。
- 同じリンクも、連続で毎回出します。
- `gh` が無い・失敗するなど、リンクを出せないときは、何も出さずに通します。操作は止まりません。
- 使用者には `systemMessage`、Claude には `additionalContext` で伝え、Claude は返答でもリンクに触れます。

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

`/dev-workflow:repo-setup` では、レビューに使うモデルを決めていなければ、使うかどうかも聞かれます（下の「レビューに使うモデル」）。

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

別の PR が先にマージされて main が進んでも、前の PR の CI の結果は古いままです。単独では通る2つの PR が組み合わさって main が壊れることがあるので、チェックの成功と、PR が最新の main を取り込んでいること（マージキューを使うときは、キューを通すこと。下の「マージキューを使う」）を、ルールセットで求められます。

```bash
# lint-result と test-result の成功と、最新の main の取り込みを、マージの条件にする（マージキューを使っていれば、取り込みは求めない）
plugins/dev-workflow/scripts/setup/setup-repo.sh --required-check lint-result --required-check test-result
```

- `--required-check` は、`setup-all.sh` にも渡せます。繰り返し指定できます。
- 指定した名前の一覧で、必須のチェックを置き換えます。CI を足したり外したりしたときは、新しい一覧で実行し直します。付けなければ、ルールセットの必須のチェックの一覧には触れません。GitHub の設定画面で直した必須のチェックも、そのまま残ります。ただし、最新の main の取り込み（strict）は、マージキューの有無で決まります。キューを使っていれば、オプションが無くても外します。使っていなければ、`--required-check`・`--no-merge-queue` のときに求め、どちらも無ければ今のままです。
- チェックの名前は、チームの CI で決まるので、プラグインは決めません。CI が無いリポジトリや、まだ報告されたことのない名前を指定すると、チェックが「待ち」のまま残ってマージできなくなります。名前は、そのチェックが一度動いてから指定してください。
- 名前は、CI 全体の結果を1つにまとめる「門番のジョブ」にすることをおすすめします。ジョブを足しても、必須の名前は変わらずに済みます。ジョブごとに必須にすると、CI の変更のたびにこのコマンドを実行し直すことになります。
- `paths-ignore` などでワークフローが動かない PR（ドキュメントだけの変更など）は、そのチェックが報告されず、「待ち」のままマージできなくなります。`paths-ignore` はやめ、変更の範囲を見て重いジョブを `if` で飛ばしたうえで、門番のジョブは必ず動かして成功にしてください（このリポジトリの `.github/workflows/lint.yml`・`test.yml` が例です）。

#### マージキューを使う

最新の main の取り込みを求めると、別の PR がマージされるたびに、残りの PR へ main を取り込み直して CI を通し直すことになります。マージキューを使うと、キューが最新の main と組み合わせた結果で CI を動かして順にマージするので、取り込み直しが要らなくなります。

```bash
# マージキュー（スカッシュ）を使い、必須のチェックの「最新の main の取り込み」を外す
plugins/dev-workflow/scripts/setup/setup-repo.sh --merge-queue --required-check lint-result --required-check test-result

# マージキューを外し、必須のチェックには最新の main の取り込みを求める
plugins/dev-workflow/scripts/setup/setup-repo.sh --no-merge-queue
```

- マージキューは、Organization の公開リポジトリと、GitHub Enterprise Cloud の Organization の非公開リポジトリで使えます。個人のアカウントのリポジトリでは使えないので、`--merge-queue` は止まります。使えるかは、出力の `merge_queue.available` で分かります。
- `--merge-queue`・`--no-merge-queue` は、`setup-all.sh` にも渡せます。どちらも付けなければ、キューを今のまま使う・使わないままにします。
- 必須のチェックを求めるワークフローは、`merge_group` のイベントでも動くようにしてください（`on: merge_group`）。動かないと、キューのチェックが「待ち」のまま残ってマージされません。`setup-repo.sh` は、base_branch の `.github/workflows/` を読んで、必須のチェック（ほかのルールセットと古いブランチ保護が求めるものも含めます）のジョブがあるワークフローが `merge_group` で動くかを確かめ、出力の `merge_queue.merge_group` に出します（`--dry-run` でも、キューを使わないときも確かめます）。チェックの名前は、GitHub がジョブのチェックに付ける名前（`name:` があればその値、無ければジョブの ID）と突き合わせるので、どのジョブとも対応しない名前（外部のアプリのチェックなど）は確かめられません。`${{ }}` の式を含む `name:` のジョブ（matrix の値を名前に入れたものなど）とも突き合わせないので、そのチェックも確かめられません。確かめたいときは、式を含まない名前のジョブ（CI 全体の結果をまとめる門番のジョブなど）を必須のチェックにしてください。ジョブの `if:` で `merge_group` を除いていても（`if: github.event_name != 'merge_group'` など）、キューでは動きません。飛ばされたジョブのチェックは成功とみなされるので、キューは CI を動かさないまま PR をマージしてしまいます。そこで、必須のチェックのジョブと、そのジョブが `needs:` でたどれるジョブの `if:` も読み、`merge_group` を除いていれば「動かない」とし、ジョブの `if:` を直すよう案内します。`if: always()` などの門番のジョブが頼るジョブを除いているときは、門番は動くものの、CI を動かしたかは結果の確かめ方次第なので、「確かめられない」とします。出力の `merge_queue.merge_group.not_running` には、動かないチェックを、直す場所（`reason`。ワークフローの `on:` に `merge_group` が無ければ `on`、ジョブの `if:` で除いていれば `if`）と一緒に出します。`github.event_name` を `==`・`!=` で比べるだけの項は読み分けますが、それ以外に `github.event`・`github.head_ref`・`github.base_ref`・`github.ref`・`merge_group` を使う式（`github.event.pull_request.draft == false` など）は、動くか確かめられないとします。再利用するワークフローの、呼ばれる側のジョブの `if:` は読みません。キューを使うときは、動かないチェックと、確かめられないチェックを警告しますが、止めはしません。キューを使わないときは、警告せずに結果を出力に出すだけです。キューを使い始めた後は、`doctor.sh` が同じことを確かめます。
- `doctor.sh` は、main にマージキューと最新の main の取り込みのどちらが効いているかを表示します。main に必須のチェックが無いときは、CI が通らなくてもマージできるので警告し（マージキューを使っていても警告します。ルールセットだけでなく、古いブランチ保護の必須のチェックも見ます。古いブランチ保護にだけ必須のチェックがあるときは、strict かが分からないので、マージキューと最新の main の取り込みのどちらが効いているかは表示しません）、`/dev-workflow:repo-setup`（`setup-repo.sh --required-check`）で設定するよう案内します。CI の無いリポジトリでこの警告を止めるには、`.claude/dev-workflow/config.json` に `"require_status_checks": false` を書きます（個人の設定 `config.local.json` やユーザーの設定では止められません）。

### レビューに使うモデル

`/dev-workflow:review` のレビュー（観点ごとのサブエージェントと `/code-review`）を、セッションとは別のモデルで動かせます。使うかどうかは任意で、既定では使いません（いつもセッションと同じモデルで動きます）。セッションより下のモデルにして費用を抑えることも、セッションを Sonnet にしたままレビューだけ Opus で深く見ることもできます。

```bash
# このリポジトリで、自分のレビューを Opus で動かす（opus・sonnet・haiku・fable から選べます。config.local.json に書きます）
plugins/dev-workflow/scripts/setup/setup-models.sh --review-model opus --scope local

# チームで、レビューをセッションと同じモデルで動かすと決める（.claude/dev-workflow/config.json に書きます）
plugins/dev-workflow/scripts/setup/setup-models.sh --review-model off --scope team

# 今の設定と、どの層で決めてあるかを確かめる
plugins/dev-workflow/scripts/setup/setup-models.sh
```

- 書く層は、`local`（`.claude/dev-workflow/config.local.json`。自分だけ）か `team`（`.claude/dev-workflow/config.json`。コミットしてチームで共有します）です。設定ファイルの `review.model` を直接書いてもかまいません。
- `~/.claude/dev-workflow/config.json` に `review.model` を書くと、ほかの設定と同じく、導入したすべてのリポジトリに効きます（リポジトリの層で決めた値が優先されます）。`setup-models.sh` はユーザーの層には書きません。
- 契約や組織の制限で使えないモデルを指定すると、Claude Code が別のモデルに置き換えて動かします。
- 対象はレビューだけです。commit などの短いスキルは、別のモデルに任せる手間でかえって費用が増えるので、いつもセッションと同じモデルで動きます。
- 計った結果（[設計書 §7](docs/design.md#7-レビュー)）：費用の半分ほどはセッションのモデルで動く進行役の分なので、`sonnet` に下げても、レビュー1回の費用は17%ほどしか減りません。`haiku` はトークンを多く使うので `sonnet` より得にならず、時間は倍以上かかります。セッションを Sonnet にしたままレビューだけを `opus` にすると、セッションを Opus にしたときと同じくらいの費用で、レビューを Opus で行えます。
- `local` に書いたとき、`config.local.json` が git に無視されていなければ警告します。`.gitignore` に `.claude/dev-workflow/config.local.json` を足してください。既にコミットしてあるときは、`.gitignore` に書くだけでは追跡が外れないので、`git rm --cached .claude/dev-workflow/config.local.json` で外すよう警告します。
- `--review-model`・`--models-scope` は、`setup-all.sh` にも渡せます。

## 開発

開発に参加するときの環境の準備・開発の流れ・テストは [CONTRIBUTING.md](CONTRIBUTING.md) を参照してください。
