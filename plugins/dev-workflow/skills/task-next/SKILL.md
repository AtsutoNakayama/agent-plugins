---
name: task-next
description: GitHub Project の Todo の Issue から、次に着手すべきものと、同時に進められる組を提案する。優先順位（Todo の上から順）・依存（blocked by と本文の「依存」）・コンフリクトの見込み（本文の「変更するファイル・領域」と着手中の PR のファイル）を見る。何も変えない読み取り専用。「次に何をやればいい？」「並列で進められる Issue はある？」のように、着手する Issue を選ぶときに使う。
---

# 次に着手する Issue の提案

Todo の Issue を読み、次に着手すべきものと、同時に進められる組を提案する。読むだけで、Issue・Project・ブランチ・ワークツリーのどれも変えない（確認は要らない。設計書 §8）。着手は `task-start` で、使う人が決める。herdr などの並列実行の仕組みが無くても使える。

スクリプト（JSON を出力する）:

- `${CLAUDE_PLUGIN_ROOT}/scripts/next-tasks.sh`：Todo の Issue を Project の並び順で読み、待ち・領域の重なりを判定する（`--help` で使い方）

## 手順

### 1. 読む

`next-tasks.sh` を実行する。「project.number が未設定です」なら、`/dev-workflow:repo-setup` で Project を設定できることを伝えて止める。ほかのエラーは、標準エラーの1行のメッセージをそのまま伝える。

出力の見方:

- `next`：次に着手すべき Issue の番号（待ちを除いた先頭）。無ければ null
- `parallel`：`next` と同時に進められる Issue の組（`next` を含む）
- `todo`：Todo の Issue を Project の並び順（`position`）に並べたもの。`waiting`（待ち）、`blocked_by`（まだ閉じていない依存先。`repo` と `number`、出どころ `sources`。`dependency` は GitHub の依存関係、`body` は本文の「依存」。別のリポジトリの Issue のこともある）、`areas`・`area_known`・`areas_ignored`（本文の「変更するファイル・領域」。`areas_ignored` はパスと判断できず使わなかった行）、`warnings`（着手中の Issue の領域が分からないときの警告）、`parallel` と `reason`（並列にできるか、その理由）、`overlaps`（選んだものと重なるパス）、`conflicts_with_active`（着手中の Issue と重なるパス）
- `in_progress`：着手中の Issue。`areas`（本文の領域）と `pr_files`（開いている PR が変えているファイル）、`area_known`（どちらかがあるか）。`active_unknown` は、どちらも無い着手中の Issue の番号

### 2. 提案する

次を、Issue の番号とタイトルを添えて伝える。

- **次に着手するもの**：`next`。Story Point があれば添える。`conflicts_with_active` があれば、着手中の Issue と重なりそうなパスを警告する（止めはしない）
- **同時に進められる組**：`parallel` が2つ以上あれば、その組。それぞれがどのパスを触る見込みかを添える。`next` だけなら「並列にできる組は見つからなかった」と伝え、理由（領域が不明・重なる）を添える
- **並列にできないもの**：`parallel` が false で、待ちでないものは、`reason` で伝え方が変わる。
  - 「選んだものと領域が重なる」：`overlaps` の相手とパスを添える
  - 「着手中のものと領域が重なる」：`conflicts_with_active` の相手とパスを添える（`overlaps` は付かない）
  - 「領域が不明なので、重なるか分からない」：その Issue に「変更するファイル・領域」を書けば、並列の候補にできると伝える
  - 「次に着手するものの領域が不明なので、重なるか分からない」：この Issue の領域は分かっている。`next` の Issue に「変更するファイル・領域」を書けば、並列の組を作れると伝える（書くべき Issue を取り違えない）
- **待ちのもの**：`waiting` の Issue と、待っている Issue の番号（`blocked_by`）。候補には入れない。`blocked_by` の `state` が `not_found` なら、本文の「依存」に書かれた番号の Issue が見つからない（書き間違いか、削除された）ので、番号を直すよう伝える

次の注意も、該当すれば伝える。

- `warnings` がある：着手中の Issue に領域も PR も無いので、その Issue と重なるか分からない（並列にしてよいかは、その Issue の領域を確かめてから決める）
- `areas_ignored` がある：その Issue の「変更するファイル・領域」に、パスと判断できない行がある。Issue の欄をパスで書き直せば、並列の候補にできる
- 着手中の Issue の PR は、ブランチ名（`<type>/<番号>-…`）か `Closes` で結び付ける。どちらでもない PR は結び付けられず、重なりを見逃すことがある
- gh が返す PR のファイルは、1つの PR につき最初の100件までのことがある。それを超える大きな PR では、重なりを見逃すことがある

領域の重なりは、本文のパスから見た見込みで、実際のコンフリクトとは限らない。警告として伝え、並列にしてよいかは使う人が決める。

続けて着手したいと言われたら、`/dev-workflow:task-start <番号>` を案内する（このスキルでは着手しない）。複数を同時に進めるなら、Issue ごとに別のワークツリーができる。
