---
name: repo-setup
description: リポジトリの初期設定（type ラベルと breaking ラベル、GitHub Project、スカッシュのみのマージとルールセット、PR / Issue テンプレート、レビューに使うモデル）を対話的に行う。新しいリポジトリで開発ワークフローを使い始めるときに使う。
---

# リポジトリの初期設定

今いるリポジトリを、開発ワークフローで使える状態にする。実際の処理は `setup-all.sh` が行い、このスキルは選択肢を聞いて、予定を見せ、確認を取ってから実行する。

ラベル・Project・リポジトリの設定は GitHub を変えるので、必ず手順4でユーザーの承認を得てから行う。承認なしに `--dry-run` を外して実行しない。

スクリプト（どれも JSON を出力する）:

- `${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh`：実行環境と認証の確認
- `${CLAUDE_PLUGIN_ROOT}/scripts/config.sh`：合わせた設定の出力
- `${CLAUDE_PLUGIN_ROOT}/scripts/setup/setup-all.sh`：初期設定をまとめて行う（`--help` で使い方）
- `${CLAUDE_PLUGIN_ROOT}/scripts/setup/setup-repo.sh`：マージ方法とルールセット（`setup-all.sh` が中で使う。手順2でマージキューを使えるかを読むのに使う）
- `${CLAUDE_PLUGIN_ROOT}/scripts/setup/setup-models.sh`：レビューに使うモデル（`setup-all.sh` が中で使う。手順2で、引数なしで今の設定を読むのに使う）

## 手順

### 1. 実行環境を確かめる

`doctor.sh` を実行する。`ok` が `false` なら、失敗した項目と直し方を伝えて止める。

- `gh-project-scope` が失敗：普通のターミナルで `gh auth refresh -h github.com -s project` を実行してもらう
- `gh-auth` が失敗：`gh auth login` を実行してもらう

リポジトリの外にいるときも止める。

### 2. 選択肢を聞く

`config.sh` で今の設定を、`setup-repo.sh --dry-run` でマージキューを使えるか（`merge_queue.available`）と今使っているか（`merge_queue.enabled`）を、`setup-models.sh`（引数なし）でレビューのモデルを決めてあるか（`review.decided`）を読み、決まっていないことだけを AskUserQuestion でまとめて聞く。

- **Project**：`project.number` が設定済みなら聞かない。無ければ「新しく作る（名前。既定はリポジトリ名）」か「既存の Project に接続する（番号）」か
- **GitHub の既定のラベル**（bug・enhancement など）：削除する（おすすめ）か残すか。削除すると、付いている Issue からも外れる
- **マージに必要な承認の数**：0（おすすめ。1人で開発するとき）か 1 以上か
- **マージの前に成功を求める CI のチェック**：既に決まっていれば聞かない。名前は、チームの CI でそのチェックが一度動いたものにする（CI が無い、または動いたことのない名前を指定すると、マージできなくなる）。CI が無ければ「求めない」にする。指定するときは `--required-check <名前>` を名前ごとに付ける。CI 全体の結果をまとめるジョブがあれば、その名前だけを指定する
- **マージキュー**：`merge_queue.available` が `false`（個人のアカウントのリポジトリなど）か、`merge_queue.enabled` が `true`（もう使っている）なら聞かない。それ以外は、使う（おすすめ。PR を並列で進めるとき）か使わないかを聞く。使うなら `--merge-queue` を付ける。`available` が `null` のとき（組織の非公開のリポジトリで、プランを確かめられない）は、GitHub Enterprise Cloud でないと使えないことを選択肢の説明に書く。キューを使うと、PR は「Merge when ready」でキューに入れ、キューが最新の base_branch と組み合わせた結果で CI を動かしてからマージする。必須のチェックを指定するなら、チームの CI のワークフローが `merge_group` のイベントでも動くようにしておく（動かないと、キューのチェックが「待ち」のままマージされない）。そのことも説明に書く。既に必須のチェックがあれば、`setup-repo.sh --dry-run` の `merge_queue.merge_group` に、そのワークフローが `merge_group` で動くかが出る。`not_running` があれば、「使う」の説明に、そのチェックとワークフローのファイルを挙げ、ワークフローの `on:` に `merge_group` を足さないとマージされなくなることを書く。`unknown` があれば、そのチェックは動くか確かめられなかったことを書く
- **レビューに使うモデル**：`review.decided` が `true`（このリポジトリのどちらかの層で、使うか使わないかを決めてある）なら聞かない。それ以外は、review スキルのレビュー（観点ごとのサブエージェントと `/code-review`）を、セッションとは別のモデルで動かすかを聞く。使わない（おすすめ。いつもセッションと同じモデルで動く）か、使うか。あわせて、決めたことを保存する場所を聞く：自分だけ（おすすめ。`config.local.json`。git に無視される。使えるモデルは契約や組織の制限で人ごとに違うため）・チーム（`config.json`。コミットして共有する）。どちらもこのリポジトリの中のファイルで、ほかのリポジトリには効かない。使うを選んだら、続けてモデルを聞く：opus・sonnet・haiku・fable。選択肢の説明には、セッションのモデルより上のモデルを選ぶとレビューの費用が増え、下のモデルを選ぶと減るが見落としが増えうること、契約や組織の制限で使えないモデルは Claude Code が別のモデルに置き換えることを書く。使うなら `--review-model <モデル>`、使わないなら `--review-model off` を、どちらも `--models-scope <local・team>` と一緒に付ける（使わないことも保存し、次からは聞かない）

### 3. 予定を見せる

選んだオプションに `--dry-run` を付けて `setup-all.sh` を実行し、`labels.actions`・`project.actions`・`repo.actions`・`models.actions`・`templates` を、変わることが分かる短い一覧にして見せる。変更が無い項目は「変更なし」とまとめる。

ルールセットを作るときは、次のことも伝える。

- 以後、`repo.branch` へ直接 push できなくなり、PR が必須になる。管理者も例外にしない
- マージはスカッシュだけになる
- チェックを指定したときは、そのチェックの成功が、マージの条件になる。マージキューを使わないなら、PR が最新の `repo.branch` を取り込んでいることも条件になる
- マージキューを使うときは、PR をキューに入れてマージする（最新の `repo.branch` を取り込み直す必要はない）。必須のチェックは `merge_group` のイベントでも動く必要がある。`repo.merge_queue.merge_group` の `not_running` に挙がったチェック（とワークフローのファイル）は動かないので、予定の一覧に挙げ、キューを使う前にワークフローの `on:` に `merge_group` を足すよう伝える。`unknown` に挙がったチェックは、動くか確かめられなかったことを伝える

### 4. 確認を取って実行する

AskUserQuestion で、実行してよいか確認を取る（会話の中のあいまいな返事を承認とみなさない）。選択肢の説明には、選ぶと実際に何が起きるか（作るもの・削除するもの・GitHub に書き込むもの）を書き、`--dry-run` などのフラグやスクリプト名といった内部の手順は書かない（設計書 §8）。例：「実行する」の説明は「type ラベルと breaking ラベルを作り、Project を作ってつなぎ、main への直接 push を禁止する」。手順3で見せた予定の一覧は、質問の中にも入れる（設計書 §8。別の端末から使うと、質問の直前の文章が見えないことがある）。各選択肢の preview に、予定の一覧とルールセットについての注意を入れる。承認されたら、同じオプションで `--dry-run` を外して実行する。失敗したら、標準エラーの1行のメッセージをそのまま伝える（例：非公開のリポジトリで、プランによってルールセットを使えない）。

### 5. 次にやることを伝える

出力の `next_steps` を伝える。

- **作ったファイル**（テンプレート、`.claude/dev-workflow/config.json`）はコミットされていない。直接 push できないので、Issue を起票し、ブランチを切って PR にする
- **レビューに使うモデル**は、後から `setup-models.sh --review-model <モデル か off> --scope <層>` で変えられる（設定ファイルの `review.model` を直接直してもよい）
- **自動追加（Auto-add to project）** が無効なら、URL の画面で有効にしてもらう。有効にした後に `setup-all.sh --dry-run` をもう一度実行すると、`project.workflows.auto_add` が `true` になったか確かめられる
