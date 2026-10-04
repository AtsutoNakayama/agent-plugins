# 開発への参加

このリポジトリを開発する人向けの手順とルールです。プラグインの使い方は [README](README.md)、設計は [docs/design.md](docs/design.md) を参照してください。

## 環境の準備

必要なもの：`git`、`gh`、`jq`、`shellcheck`（CI と同じ版）、`bats`（bats-core）、`actionlint`（shellcheck と actionlint は、無ければ Docker で実行できます。下の「テストとチェック」）。bats を並列に実行するなら GNU `parallel` も使います

テストの補助ライブラリ（bats-support・bats-assert）は git submodule で同梱しています。

```bash
git submodule update --init   # 初回だけ
```

開発中のプラグインを Claude Code に読み込んで試す方法は、README の「使い方」を参照してください。

## 開発の流れ

このリポジトリ自身も dev-workflow プラグインのワークフローで開発します。

1. **Issue を起票します**（`/dev-workflow:task-create`）。作業はすべて Issue から始めます。
2. **着手します**（`/dev-workflow:task-start`）。ブランチとワークツリー（`.claude/worktrees/<ブランチ名>`）ができるので、以後はその中で作業します。
3. **コミットします**（`/dev-workflow:commit`）。全部を直し終えてから1回でコミットするのではなく、論理的な区切り（1つの変更を仕上げてテストが通ったところ）ごとにコミットします。
4. **PR を出します**（`/dev-workflow:pr-create`）。出す前に、下の「テストとチェック」がすべて通ることを確かめます。main が先に進んだ PR は、最新の main を取り込んで CI が通り直すまでマージできません（下の「コミットと PR の規約」のマージの条件）。
5. **後片付けをします**（`/dev-workflow:task-finish`）。PR がマージされたら、ワークツリーとローカルのブランチを削除し、main を最新にして、PR が閉じる Issue が閉じたかも伝えます。

レビューの観点（`.claude/dev-workflow/review/`）の追加・修正は、そのきっかけになったタスクの PR に含め、別の Issue にはしません。`/dev-workflow:review-perspective-add` は、今のタスクのワークツリーで実行します。

Issue をやめることにしたときは、`/dev-workflow:task-cancel` を使います。理由と参照先をコメントして not planned（重複なら duplicate）で閉じ、着手していれば PR を閉じて、ブランチとワークツリーも削除します。

### コミットと PR の規約

- コミットメッセージは [Conventional Commits](https://www.conventionalcommits.org/ja/v1.0.0/)（`<type>(<scope>): <要約>`）で書きます。type は `plugins/dev-workflow/defaults/workflow.json` の `commit.types` のどれかです。
- PR のタイトルは `<type>: <Issueのタイトル>` とし、本文に `Closes #<Issue番号>` を付けます。
- マージの条件：main のルールセットは、`lint-result` と `test-result` の成功と、PR が最新の main を取り込んでいることを求めます。別の PR が先にマージされて main が進んだら、PR に main を取り込み（PR の「ブランチを更新」か `git merge origin/main`）、CI が通り直すのを待ってからマージします。古い main で通った CI の結果のままだと、先にマージされた変更と組み合わさって main が壊れることがあるためです（#108）。
- マージはスカッシュのみです。main への直接 push・強制 push はルールセットとフックで禁止されています。
- プラグインのラベルの定義（`plugins/dev-workflow/defaults/labels.json`）を変えた PR では、このリポジトリでも `plugins/dev-workflow/scripts/setup/setup-labels.sh` を実行して、ラベルを定義に揃えます。定義を変えても、既にあるリポジトリのラベルは変わらず、足したラベルが無いと起票などで止まります（`doctor.sh` が足りないラベルを知らせます）。
- プラグインのバージョンは release-please がリリース PR で上げます。`plugin.json` の `version` や `.release-please-manifest.json` を手で変えないでください。

## PR の自動レビュー

PR は、CodeRabbit（`.coderabbit.yaml`）が作ったときと、push のたびに（増分で）自動でレビューします。これは CodeRabbit の試用期間中だけの暫定の運用で、試用期間が終わったら、作ったときに1回だけレビューする運用に戻します（#160）。指摘への対応は、下の「指摘に手元の Claude Code で対応する」のとおり、返信で行います。CodeRabbit のレビューは1時間あたりの回数に上限があり、上限で失敗したレビューは自動では再試行されません。そこで、次のときは Claude が代わりにレビューして PR にコメントします（`.github/workflows/claude-review.yml`）。

- CodeRabbit が上限に引っかかったとき（`coderabbitai[bot]` の `rate limited by coderabbit.ai` のコメントがきっかけです）
- PR を作ってから1時間経っても CodeRabbit のレビューが無いとき（30分ごとに見回ります。障害など上限以外の理由で動かなかった場合も拾います）

Claude のレビューは、上限のコメントがきっかけのときは同じコミットに1回しか付きません（試用期間中は、push のたびに CodeRabbit のレビューが上限に当たりやすく、上限に当たった push のコミットごとに付くので、PR あたりの数が増えることがあります）。見回りは、その PR に Claude のレビューが1件でもあれば動かないので、CodeRabbit が動かない状況でも、レビューが際限なく付くことはありません。head が同じリポジトリの PR だけが対象で、フォークからの PR は対象外です。どちらのレビューも、この CONTRIBUTING.md と `plugins/dev-workflow/review/*.md`・`.claude/dev-workflow/review/*.md` のレビューの観点に沿って行います。ワークフローは必須のチェックではないので、失敗しても PR のマージは妨げません。

### 設定の手順

1. CodeRabbit の GitHub App をこのリポジトリに入れます（公開リポジトリは OSS プランで無料です）。
2. 手元で `claude setup-token` を実行して OAuth トークンを作り、リポジトリのシークレット `CLAUDE_CODE_OAUTH_TOKEN` に登録します。

### 指摘に手元の Claude Code で対応する

試用期間中は、push のたびに CodeRabbit が増分でレビューします（試用期間が終わったら、PR を作ったときの1回だけに戻します。#160）。指摘には返信して resolved にしていきます。この流れは、このリポジトリ専用の skill `.claude/skills/coderabbit-respond/`（プラグインには同梱しません）で行えます。

- 試用期間中は、push のたびに自動でレビューされるので、`@coderabbitai review` は要りません。試用期間が終わったら、`@coderabbitai review` は使いません（1回ごとにレビューの上限を消費し、使った後の PR では、push のたびに増分のレビューが走って上限を消費するためです）。ただし、試用期間が終わった後でも、PR を作ったときのレビューが、障害などで付かなかったときだけ、1回使ってかまいません（Claude の見回りが拾うのを待たなくて済みます）。
- 指摘は `gh` で読みます。行ごとの指摘はスレッドで、diff の外の指摘はレビュー本文にあります。

  ```bash
  gh pr view <PR番号> --comments                                  # Claude のレビューと CodeRabbit の要約
  gh api repos/{owner}/{repo}/pulls/<PR番号>/comments             # CodeRabbit の行ごとの指摘
  ```

- 直した指摘は、そのスレッドに、直したコミットを添えて `@coderabbitai` 付きで返信します。CodeRabbit が現在のコードを読み、直っていれば resolved にします。チャットのメッセージは、PR のレビューとは別の上限です。
- diff の外の指摘はスレッドが無いので、PR のコメントに `@coderabbitai` を付けて、同じように確認させます。
- 直さない指摘は、理由を返信します。resolved にするのは、直したか、理由に合意できたものだけにします。
- `@coderabbitai resolve` でまとめて resolved にしません。

## 書き方のルール

- **macOS 標準の bash 3.2 で動くように書きます**。連想配列（`declare -A`）、`mapfile` / `readarray`、`${var,,}` などの bash 4 以降の機能は使いません。スクリプトの先頭には `set -euo pipefail` を書きます。
- 日本語などの ASCII 以外の文字が変数の直後に続くときは、`"${var}」"` のように波括弧で囲みます（bash 3.2 は `"$var」"` の `」` のバイトまで変数名とみなします。CI で検査しています）。
- **スキルから呼ぶファイルは `plugins/dev-workflow/` の中に置きます**。プラグインとしてインストールされるのはこのディレクトリだけなので、外に置いたファイルは使う人の環境にありません。スキルからは `${CLAUDE_PLUGIN_ROOT}/scripts/...` のように参照します。
- **shellcheck を通します**。警告を抑えるときは、理由をコメントに書きます。
- スクリプトの出力は JSON、エラーは終了コードと1行のメッセージにします。初期設定用のスクリプト（`scripts/setup/`）は `--dry-run` に対応します（設計書 §10）。

## テストのルール

- **スクリプトを変えたら、bats のテスト（`tests/*.bats`）を足します**。GitHub を使うスクリプトは、`gh` を偽物（`tests/fake_gh.bash` など）に置き換えて、GitHub に触れずに試します。
- **不具合を修正するときは、その不具合がもう一度起きないことを確かめるテストを必ず足します**。修正前のコードでは失敗し、修正後に通ることを確かめてからコミットします。
- **不具合を修正するときは、同じ原因の他の箇所も探します**。同じ書き方・同じ前提で書かれた場所を `git grep` などで検索し、同じ誤りが残っていれば同じ変更で直して、その分のテストも足します。直した後に、同じ検索をもう一度実行して残りが無いことを確かめます。

## テストとチェック

PR を出す前に、次がすべて通ることを確かめます。どれも CI でも実行します（shellcheck・actionlint・`claude plugin validate` などは `.github/workflows/lint.yml`、bats は `.github/workflows/test.yml`）。ただし、`README.md`・`docs/`・Issue と PR のテンプレート（`.github/ISSUE_TEMPLATE/`・`.github/pull_request_template.md`）だけを変えた PR では、重いジョブ（lint・test）を飛ばします。ワークフローは動いて、必須のチェック（`lint-result`・`test-result`）は成功になるので、これまでどおりマージできます。

```bash
# tests/lib は外部のライブラリ（git submodule）なので対象にしない
find plugins tests .github/scripts -path tests/lib -prune -o -type f \( -name '*.sh' -o -name '*.bash' \) -print0 | xargs -0 shellcheck -x
shellcheck -s bash tests/*.bats
actionlint                         # 入っていなければ docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.12
bats tests/
TEST_BASH=/bin/bash bats tests/   # macOS では標準の bash 3.2 で確認する
claude plugin validate --strict .                     # マーケットプレイス
claude plugin validate --strict plugins/dev-workflow  # プラグイン本体（. だけではスキルなどは検査されない）
```

bats は `--jobs` で並列に実行できます（GNU parallel が要ります）。テストは git や jq の起動を待つ時間が長いので、コア数の2倍くらいにすると速くなります。各テストは自分の一時ディレクトリで動くので、並列にしても結果は変わりません。

```bash
bats --jobs "$(( $(getconf _NPROCESSORS_ONLN) * 2 ))" tests/
```

shellcheck は版によって出す指摘が違うので、CI と同じ版（`.github/workflows/lint.yml` の `SHELLCHECK_VERSION`、今は 0.11.0）を使います。CI の版を上げるときは、ここに書いた版（この段落と、下の Docker のイメージのタグ）もそろえます。手元に同じ版が無ければ、Docker で実行できます。

```bash
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck-alpine:v0.11.0 sh -c '
  find plugins tests .github/scripts -path tests/lib -prune -o -type f \( -name "*.sh" -o -name "*.bash" \) -print0 | xargs -0 -r shellcheck -x &&
  shellcheck -s bash tests/*.bats
'
```

### Docker の bash 3.2 でテストする

macOS 以外でも、Docker の `bash:3.2` イメージで macOS 標準の bash 3.2 で動くことを確かめられます。リポジトリ・ワークツリーのどこで実行しても動きます。

```bash
root=$(cd "$(git rev-parse --git-common-dir)/.." && pwd)   # 元のリポジトリ
top=$(git rev-parse --show-toplevel)                       # 今いるリポジトリまたはワークツリー
docker run --rm -v "$root:$root" -v "$top:$top" -w "$top" bash:3.2 sh -c '
  apk add --no-cache jq git bats bash parallel >/dev/null &&
  git config --global --add safe.directory "*" &&
  export PATH=/bin:/usr/bin:$PATH &&
  TEST_BASH=/usr/local/bin/bash bats --jobs "$(( $(getconf _NPROCESSORS_ONLN) * 2 ))" tests/
'
```

- bats 本体は新しい bash（apk で入れる `/bin/bash`）で動かし、対象のスクリプトだけ bash 3.2（イメージの `/usr/local/bin/bash`）で動かします。イメージでは `/usr/local/bin` が PATH の先にあるので、`PATH` を並べ替えないと bats 本体も bash 3.2 で動き、日本語のテスト名を扱えずに失敗します。
- コンテナの中はファイルの持ち主が違うので、`safe.directory` を設定しないと git がリポジトリを使えません。
- ワークツリーの `.git` はファイルで、元のリポジトリの `.git/worktrees/` を指しています。ワークツリーだけをマウントすると `fatal: not a git repository` になるので、上のように元のリポジトリ全体とワークツリーを、どちらも同じパスでマウントします（ワークツリーがリポジトリの外にあっても動きます）。ワークツリーでは、先に `git submodule update --init` も実行しておきます。
