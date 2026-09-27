---
name: pr-create
description: 作業用のブランチを push し、Issue に紐付けた PR を作る。タイトルは <type>: <Issueのタイトル>、本文は PR テンプレートに沿って概要・変更点・確認方法を書き、Closes #N を付ける。「PR を作って」のように実装を終えてレビューに出すときに使う。
---

# PR の作成

今のブランチの変更から PR の本文を書き、ユーザーの確認を取ってから `pr-create.sh` で push と PR の作成を行う。本文は AI が書き、タイトルの検証・`Closes #N`・ラベルの引き継ぎ・push・PR の作成・列の移動はスクリプトが行う。

push と PR の作成は GitHub に残るので、必ず手順4でユーザーの承認を得てから行う（設計書 §8）。承認なしに `--dry-run` を外して実行しない。

スクリプト（どれも JSON を出力する）:

- `${CLAUDE_PLUGIN_ROOT}/scripts/config.sh`：合わせた設定の出力
- `${CLAUDE_PLUGIN_ROOT}/scripts/pr-create.sh`：タイトルと本文の検証、push、PR の作成、列の移動（`--help` で使い方）

## 手順

### 1. 設定と Issue を読む

`config.sh` で次を読む。

- `language`：本文を書く言語
- `base_branch`：PR のマージ先
- `pr.template`：PR テンプレートのパス（リポジトリのルートから。`null` なら、プラグインの既定 `${CLAUDE_PLUGIN_ROOT}/templates/pull_request_template.md` の見出しを使う）
- `guides.pr`：PR の書き方のガイド（あれば読んで従う。複数あれば後ろのものを優先する）

紐付ける Issue の番号は、ブランチ名（`branch.pattern` の `{issue_number}`）から読む。分からなければユーザーに聞く。`gh issue view <番号> --json number,title,body,labels` で Issue を読む。

### 2. 変更を確かめる

- `git status` で未コミットの変更が無いか見る。あれば commit スキルでコミットしてから進める（PR に入れない変更なら、ユーザーに確かめる）
- `git log --oneline origin/<base_branch>..HEAD` と `git diff origin/<base_branch>...HEAD` で、PR に入る変更を読む

### 3. 本文を書く

PR テンプレートの見出しに沿って書く。既定のテンプレートなら次のとおり。

- **概要**：何のために何をしたかを1〜3文で
- **変更点**：変更したファイルや機能ごとに箇条書き。レビューする人が差分を読む前に全体を掴めるように、なぜそうしたかも添える
- **確認方法**：実行したテスト・確かめた手順と、その結果（件数など）。実行していないものを書かない
- `Closes #<番号>`：書かなければスクリプトが末尾に足す。テンプレートの空の `Closes #` は消してよい

タイトルはスクリプトが `<type>: <Issueのタイトル>` で作るので、`--title` は付けない。Issue のタイトルでは内容が伝わらないなど、変えたいときだけ付ける（type は Issue の type ラベルと同じにする）。

### 4. 予定を見せて確認を取る

本文を一時ファイルに書き、`pr-create.sh --issue <番号> --body-file <ファイル> --dry-run` を実行する。出力の `title`・`body`（`Closes #N` を足した後のもの）・`labels`・`actions`（push、PR の作成、列の移動）を見せ、AskUserQuestion で「この内容で PR を作る」「本文を直す」「タイトルを変える」などを選んでもらう。会話の中のあいまいな返事を承認とみなさない。

直したい点を言われたら、本文を直してもう一度 dry-run を見せる。

dry-run が止まったときは、標準エラーの1行のメッセージに従う。

- 「未コミットの変更があります」：commit スキルでコミットしてからやり直す
- 「タイトルが規約に合いません」「タイトルの type が…違います」：`--title` を直す
- 「type ラベルを1つにしてください」：どのラベルにするかユーザーに聞き、Issue のラベルを直してから進める（ラベルの変更も確認を取ってから行う）

### 5. 実行する

承認されたら、同じ引数で `--dry-run` を外して実行する。失敗したら、標準エラーの1行のメッセージをそのまま伝える。

- 「push できませんでした」：origin のブランチに手元に無いコミットがある。強制 push はせず、ユーザーに取り込み方を相談する
- 「push しましたが、PR を作れませんでした」：もう一度実行すれば、push 済みのブランチから PR を作る
- 開いた PR が既にあれば、push だけして作り直さない（`created: false`）

### 6. 結果を伝える

PR の番号と URL（`pr.number`・`pr.url`）を伝える。列を移したとき（`status.skipped` が false）は、移した列（`status.to`）も伝える。マージは人間が行う（`allow_ai_merge` が true でない限り、AI はマージしない）。
