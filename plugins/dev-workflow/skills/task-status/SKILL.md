---
name: task-status
description: Issue を GitHub Project の任意の列へ移す。利用者が追加した列（例：Blocked）へも移せる。「#12 を Blocked に移して」「#12 を Todo に戻して」のように、Issue の列を指定して移すときに使う。作業の開始（task-start）や PR の作成（pr-create）のように、スキルが自動で列を移す場面には使わない。
argument-hint: "[Issue番号] [列名]"
---

# 列の移動

Issue を Project の Status の指定された列へ移す。スキルが自動で移すのは役割の決まった列（Todo・In Progress・Done など）だけなので、利用者が追加した列（例：`Blocked`）へは、このスキルで移す（設計書 §4）。列の移動は `status-set.sh` が行う。

「#12 を Blocked に移して」という依頼で結果が決まり、列の移動は戻せるので、実行の確認は取らずに移して結果を伝える（設計書 §8）。

スクリプト（JSON を出力する）:

- `${CLAUDE_PLUGIN_ROOT}/scripts/status-set.sh`：Issue の列を移す。Project に入っていなければ追加してから移す（`--help` で使い方）

## 手順

### 1. Issue と列を読み取る

引数があれば、Issue の番号と移す先の列名として使う（`12 Blocked` のように、番号（`12` でも `#12` でもよい）、列名の順）。引数が無ければ、依頼の文章から読む。それでも分からなければ、次のようにする。

- Issue の番号が無ければ、今いるブランチ名（`git branch --show-current`）の、`branch.pattern`（`${CLAUDE_PLUGIN_ROOT}/scripts/config.sh` で読める）の `{issue_number}` の位置から読む。ブランチ名が `branch.pattern` に合わない、または `branch.pattern` に `{issue_number}` が無ければ、ブランチ名の数字を推測で使わずにユーザーに聞く（確認を取らずに移すので、読み違えると別の Issue が移る）
- 列名は、依頼に書かれたとおりに使う（「Blocked に」なら `Blocked`）。列名が無ければユーザーに聞く。日本語の言い換え（「保留に」など）から列名を推測しない

### 2. 実行する

`status-set.sh --issue <番号> --to "<列名>"` を実行する。実行の前に AskUserQuestion で確認を取らない。

止まったときや移さなかったときは、次のとおり伝える。

- 「Status 列に「…」がありません（Todo / In Progress / …）」：その列は Project に無いので、移していない。メッセージにある列の一覧を見せる。大文字と小文字の違いだけで一致する列が1つだけあれば（「blocked」に対して `Blocked` など）、依頼の列はそれと決まるので、その列名でもう一度実行する。それ以外では、似た列があっても推測で移さない
- `skipped: true`：役割の名前（`todo`・`start`・`pr_opened`・`done`）を指定し、その役割の列が設定で null になっている。列は移していないので、`reason` をそのまま伝える。列名で指定すれば移せる
- 「project.number が未設定です」：Project が設定されていない。`/dev-workflow:repo-setup` で設定できることを伝える

ほかのエラーで失敗したら、標準エラーの1行のメッセージをそのまま伝える。

### 3. 結果を伝える

移した列（`from` → `to`）を伝える。`changed` が false なら、既にその列だったので何もしていないことを伝える。`actions` に「Project に追加する」があれば、Issue を Project に追加したことも伝える。
