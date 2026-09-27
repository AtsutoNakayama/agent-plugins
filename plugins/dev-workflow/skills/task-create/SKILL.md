---
name: task-create
description: 依頼の内容から Issue を起票し、type ラベルを付けて GitHub Project に追加する。Story Point は見積もりを提案し、ユーザーが確定する。作業を Issue として登録したいときに使う。
---

# Issue の起票

依頼の内容から Issue の下書きを作り、ユーザーの確認を取ってから `issue-create.sh` で起票する。判断と文章は AI が担当し、起票・ラベル・Project への追加はスクリプトが行う。

起票は GitHub に残るので、必ず手順3でユーザーの承認を得てから行う。承認なしに `issue-create.sh` を実行しない。

スクリプト（どれも JSON を出力する）:

- `${CLAUDE_PLUGIN_ROOT}/scripts/config.sh`：合わせた設定の出力
- `${CLAUDE_PLUGIN_ROOT}/scripts/issue-create.sh`：起票・ラベル・Project への追加・Status と Story Point の設定（`--help` で使い方）

## 手順

### 1. 設定を読む

`config.sh` で次を読む。

- `language`：Issue を書く言語
- `labels.types`：付けられる type ラベル
- `detected.issue_templates`：リポジトリの Issue テンプレート（あれば本文の見出しをそれに合わせる）
- `guides.issue`：Issue の書き方のガイド（あれば読んで従う。複数あれば後ろのものを優先する）

### 2. 下書きを作る

依頼の内容から次を考える。分からないことは推測で埋めず、ユーザーに聞く。

- **タイトル**：何をするかが一目で分かる短い文。type（`feat:` など）は付けない（ラベルで表す）
- **type ラベル**：`labels.types` から1つ選ぶ。`ci` は CI/CD パイプラインの変更、`build` はビルドの設定・依存関係・Dockerfile の変更、`hotfix` は本番の緊急の修正
- **本文**：Issue テンプレートがあればその見出しに沿う。無ければ「背景」「やること」（チェックリスト）「完了条件」
- **Story Point**：1, 2, 3, 5, 8, 13, 21, 34 から、作業の大きさ・不確かさ・リスクで見積もり、理由を1文で添える

### 3. 確認を取る

タイトル・type・Story Point（と理由）・本文をまとめて見せ、AskUserQuestion で確認を取る。選択肢は「この内容で起票する」「Story Point を変える」「空欄にする」など。ユーザーが直したい点を言えば、下書きを直してもう一度見せる。

Story Point が 21 か 34 になるとき（見積もりでも、ユーザーの指定でも）は、見積もりの精度が低いので、先に Issue の分割を提案する。どう分けるか（例：調査と実装、機能ごと）の案を添え、「分割する」「このまま設定する」を選んでもらう。「このまま」なら、その値で起票する。34 より大きくなりそうな作業は、分割してから起票する。

### 4. 起票する

手順3で承認されたら、本文を一時ファイルに書き、`issue-create.sh --title ... --type ... --body-file <ファイル> [--story-point N]` を実行する。Story Point が空欄なら `--story-point` を付けない。

失敗したら、標準エラーの1行のメッセージをそのまま伝える。「Issue #N は作りましたが…」のときは Issue は作られているので、もう一度起票しない。

### 5. 結果を伝える

Issue の番号と URL、Project の列（`project.status`）と Story Point を伝える。`project` が `null` なら、Project が未設定なので `repo-setup` を案内する。
