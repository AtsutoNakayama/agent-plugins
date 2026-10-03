---
name: task-create
description: 依頼の内容から Issue を起票し、type ラベルを付けて GitHub Project に追加する。Story Point は見積もりを提案し、ユーザーが確定する。作業を Issue として登録したいときに使う。
---

# Issue の起票

依頼の内容から Issue の下書きを作り、ユーザーの確認を取ってから `issue-create.sh` で起票する。判断と文章は AI が担当し、起票・ラベル・Project への追加はスクリプトが行う。

起票は GitHub に残るので、必ず手順3でユーザーの承認を得てから行う。承認なしに `issue-create.sh` を実行しない。

スクリプト（どれも JSON を出力する）:

- `${CLAUDE_PLUGIN_ROOT}/scripts/config.sh`：合わせた設定の出力
- `${CLAUDE_PLUGIN_ROOT}/scripts/issue-create.sh`：起票・ラベル（type と breaking）・Project への追加・Status と Story Point の設定・依存関係（blocked by）の登録・親の Issue への紐付け（サブ Issue。`--help` で使い方）

## 手順

### 1. 設定を読む

`config.sh` で次を読む。

- `language`：Issue を書く言語
- `labels.types`：付けられる type ラベル
- `sub_issues.max_depth`：親子の Issue の深さの上限（一番上の Issue が1層目）
- `detected.issue_templates`：リポジトリの Issue テンプレート（あれば本文の見出しをそれに合わせる）
- `guides.issue`：Issue の書き方のガイド（あれば読んで従う。複数あれば後ろのものを優先する）

### 2. 下書きを作る

依頼の内容から次を考える。分からないことは推測で埋めず、ユーザーに聞く。

- **タイトル**：何をするかが一目で分かる短い文。type（`feat:` など）は付けない（ラベルで表す）
- **type ラベル**：`labels.types` から1つ選ぶ。`ci` は CI/CD パイプラインの変更、`build` はビルドの設定・依存関係・Dockerfile の変更
- **破壊的変更か**：既存の利用者が設定やコマンドを直さないと動かなくなる変更なら、破壊的変更とする。type とは別に `breaking` ラベルを付ける（PR のタイトルが `<type>!: …` になり、major の version が上がる）
  - 例：設定ファイル（`.claude/dev-workflow/config.json` など）のキーやプレースホルダの名前の変更、スクリプトの引数の変更・削除、スキル名の変更
  - 「version を上げたいから付ける」ものではない。破壊的変更を伴わない節目（1.0.0 など）は、release-please の `release-as` などで上げる
  - 当たるか迷うときは、ユーザーに聞く。破壊的変更なら、本文の「背景」か「やること」に、利用者が何を直す必要があるか（移行のしかた）を書く
- **本文**：Issue テンプレートがあればその見出しに沿う。無ければ「背景」「やること」（チェックリスト）「完了条件」「依存」
- **依存する Issue**：この作業より先に終わらせる必要がある Issue。依頼の内容や、開いている Issue（`gh issue list --state open`）から考える。本文の「依存」に `- #N` の形で1行ずつ書き、無ければ「- なし」と書く（テンプレートに「依存」の見出しが無くても、依存があれば「依存」の見出しを足して書く）。「〜の Issue の後に」のように文章だけで書かず、必ず番号で書く
- **親の Issue**：大きな仕様を分けた一部なら、その仕様の Issue を親にする（起票した Issue は親のサブ Issue になる）。依頼で親を指定されたときや、開いている Issue に明らかな親があるときに考え、迷うときはユーザーに聞く。親子の深さが `sub_issues.max_depth` を超える紐付けはできない
- **Story Point**：1, 2, 3, 5, 8, 13, 21, 34 から、作業の大きさ・不確かさ・リスクで見積もり、理由を1文で添える。Story Point は子の Issue にだけ付け、親になる Issue（サブ Issue を持つ、または持たせる予定の Issue）は空欄にする（親の大きさは子の合計で分かり、親にも付けると二重に数えるため）

### 3. 確認を取る

タイトル・type・破壊的変更か・Story Point（と理由）・依存する Issue（番号とタイトル）・親の Issue（番号とタイトル）・本文をまとめて見せ、AskUserQuestion で確認を取る。選択肢は「この内容で起票する」「Story Point を変える」「空欄にする」など。選択肢の説明には、選ぶと実際に何が起きるか（作るもの・削除するもの・GitHub に書き込むもの）を書き、`--dry-run` などのフラグやスクリプト名といった内部の手順は書かない（設計書 §8）。例：「この内容で起票する」の説明は「Issue を起票し、fix ラベルと Story Point 3 を付けて Project の Todo に追加する」（破壊的変更なら「feat と breaking のラベルと…」のように、breaking ラベルも書く）。見せた内容は、質問の中にも入れる（設計書 §8。別の端末から使うと、質問の直前の文章が見えないことがある）。各選択肢の preview に、タイトル・ラベル・Story Point・依存・親と本文の全文を入れる。親を指定するなら、「この内容で起票する」の説明に「#12 のサブ Issue にする」のように書く。ユーザーが直したい点を言えば、下書きを直してもう一度見せる。

Story Point が 21 か 34 になるとき（見積もりでも、ユーザーの指定でも）は、見積もりの精度が低いので、先に Issue の分割を提案する。どう分けるか（例：調査と実装、機能ごと）の案を添え（元の Issue を親にして、分けた Issue をそのサブ Issue にする案も選べる。その親の Story Point は空欄にする）、「分割する」「このまま設定する」を選んでもらう。分割の案は、各選択肢の preview にも入れる（設計書 §8）。「このまま」なら、その値で起票する。34 より大きくなりそうな作業は、分割してから起票する。

### 4. 起票する

手順3で承認されたら、本文を一時ファイルに書き、`issue-create.sh --title ... --type ... --body-file <ファイル> [--breaking] [--story-point N] [--blocked-by N]... [--parent N]` を実行する。破壊的変更なら `--breaking` を付ける。Story Point が空欄なら `--story-point` を付けない。依存する Issue ごとに `--blocked-by N` を付ける（本文の「依存」と同じ番号にする）。親の Issue があれば `--parent N` を付ける。

1回の依頼で複数の Issue を起票するときは、手順2・3でまとめて下書きと確認をし、依存される側から順に、親と子なら親から先に起票する。まだ起票していない Issue への依存は、下書きでは「（1つ目の Issue）」のように仮に書いておき、先に起票した Issue の番号が分かったら、後の Issue の本文の「依存」と `--blocked-by`（親なら `--parent`）にその番号を使う。

失敗したら、標準エラーの1行のメッセージをそのまま伝える。「breaking ラベルがありません」のときは、`repo-setup`（ラベルの設定）を案内する。「親子の深さが上限の … 層を超えます」のときは、何も起票されていないので、親を一段上の Issue にするか、深さの上限（`sub_issues.max_depth`）を上げるかをユーザーに聞く。「Issue #N は作りましたが…」のときは Issue は作られているので、もう一度起票しない。

### 5. 結果を伝える

Issue の番号と URL、破壊的変更として起票したか（`breaking`）、Project の列（`project.status`）と Story Point、依存する Issue（`blocked_by`）、親の Issue（`parent`）を伝える。`project` が `null` なら、Project が未設定なので `repo-setup` を案内する。
