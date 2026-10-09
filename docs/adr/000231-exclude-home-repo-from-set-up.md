---
status: "accepted"
date: 2026-10-09
issue: 231
---

# ホームのリポジトリは導入したとみなさず、ユーザーの層をチームの設定として読み書きしない

## 背景と課題

[ADR 000219（プラグインが効く範囲）](000219-limit-scope-to-set-up-repos.md) は、チームの設定 `.claude/dev-workflow/config.json` があるリポジトリを「導入したリポジトリ」とし、導入していなければフックもユーザーの層（`~/.claude/dev-workflow/`）も効かせないと決めた。ところが、ホームをリポジトリにしている（dotfiles を `~/.git` や、`--git-dir=~/.cfg --work-tree=~` の bare リポジトリで管理している）と、チームの設定の置き場所 `<ルート>/.claude/dev-workflow` が、ユーザーの層の置き場所 `~/.claude/dev-workflow` と同じ場所になる。そのため、次のことが起きた。

* ユーザーの層の `config.json` があるだけで、ホームの下のリポジトリでないディレクトリがすべて導入したとみなされ、フックが動き、`config.sh` はユーザーの層のファイルをチームの設定としても読む。
* `setup-models.sh`（`--scope team`）・`setup-project.sh`（`--write-config`）がユーザーの層のファイルに書き、その値が導入したリポジトリのすべてに効く。
* `doctor.sh`・`setup-repo.sh` が、ユーザーの層の `base_branch`・`require_status_checks` をチームの設定として読む。個人の上書き `config.local.json` も、ユーザーの層のファイルを指す。

読む側だけを直すと、書く側・案内・guard-git の HEAD で判断する経路に食い違いが残る。

## 判断の決め手

* ユーザーの層のファイルを、チームの設定としても個人の上書きとしても読み書きしないこと
* 読む側・書く側・案内・フックで、判定の根拠が1つであること
* ディレクトリがまだ無いときや、シンボリックリンクを通した同じ場所も見分けること
* 導入できないリポジトリで、使う人が理由と次にすることを分かること

## 検討した案

* チームの設定の置き場所を決める関数を1つ作り、ユーザーの層と同じ場所（実体で比べる）なら空にする。読む側はその関数の結果を使い、書く側は空なら理由を伝えて止まる
* 読む側だけを直し、書く側は今のままにする
* ホームのリポジトリかを、ホームのディレクトリ（`$HOME`）との一致で判定する

## 判断の結果

選んだ案：「チームの設定の置き場所を決める関数を1つ作る」。理由は、決め手をすべて満たし、`WORKFLOW_USER_DIR` で置き場所を変えたときも同じ判定になるため。

* `lib/common.sh` の `dw_team_dir <ルート>` が、`<ルート>/.claude/dev-workflow` を出力する。ユーザーの層の置き場所（`dw_user_dir`）と同じ場所なら何も出力しない。ディレクトリがまだ無ければ、あるところまでの実体を解いて比べ（`dw_physical_path`）、シンボリックリンクも実体で比べる。この「出力が空のリポジトリ」をホームのリポジトリと呼ぶ（`dw_is_home_repo`）。
* 読む側（`dw_is_set_up`・`config.sh`・`review-perspectives.sh`・`dw_review_model_layers`・`dw_local_config_file`・`doctor.sh`・`setup-repo.sh`・`setup-labels.sh`・`task-flow.sh`）は、チームの設定の置き場所を `dw_team_dir` で求める。ホームのリポジトリは導入したとみなさず、`config.local.json`・文章のガイド・リポジトリの層の観点も、ユーザーの層のファイルを読まない。
* 書く側（`setup-all.sh`・`setup-project.sh --write-config`・`setup-models.sh`・`checks-commands.sh --save`・`review-perspective-add.sh --layer repo`）は、ホームのリポジトリでは何も書かず、理由を伝えて終了コード 2 で止まる。`setup-all.sh`・`setup-project.sh` は、GitHub に何かを作る前に止まる。`review-perspective-add.sh --layer user` はユーザーの層に作れるが、ここでは使われないことを警告する。
* guard-git は、ルートが分からず HEAD にコミットされたチームの設定で判断する経路でも、作業ツリーを `--work-tree`・`GIT_WORK_TREE` で指していて、それがホームのリポジトリなら、導入したとみなさない（bare の dotfiles を `--work-tree=~` で指したとき）。HEAD にあるのは、ユーザーの層のファイルをコミットしたものだからである。
* `doctor.sh` は、ホームのリポジトリで、導入できないことを知らせ、repo-setup を案内しない。
* ホームのリポジトリのワークツリー（メインのワークツリーがホームのリポジトリ）は、コミットされたユーザーの層のファイルの写しがユーザーの層とは別の場所にあるが、`dw_is_set_up` は導入したとみなさない（メインのワークツリーで判定する）。

### 結果として起きること

* 良い点：ホームをリポジトリにしていても、ユーザーの層の設定が、チームの設定としてホームの下のすべてのディレクトリに効くことは無い。
* 良い点：ユーザーの層は、導入したリポジトリでだけ、今までどおり効く。
* 悪い点：ホームのリポジトリそのものには、導入できない。導入するリポジトリは、ホームの下の別のリポジトリにする。
* 悪い点：ルートが分からず、作業ツリーも指していない bare リポジトリでは、ホームのリポジトリかを見分けられない（HEAD の設定で判断する）。

### 確認

`tests/common.bats` で `dw_team_dir`（同じ場所・まだ無いディレクトリ・シンボリックリンク）と `dw_is_set_up` を確かめる。`tests/config.bats`・`tests/review-perspectives.bats`・`tests/setup-repo.bats`・`tests/setup-labels.bats`・`tests/task-flow.bats` で読まないことを、`tests/setup-models.bats`・`tests/setup-project.bats`・`tests/setup-all.bats`・`tests/checks-commands.bats`・`tests/review-perspective-add.bats` で書かずに止まることを、`tests/guard-git.bats` で bare の dotfiles を `--work-tree` で指したときに止めないことを、`tests/doctor.bats` で案内を確かめる。

## 各案の長所と短所

### チームの設定の置き場所を決める関数を1つ作る

* 良い点：読む側・書く側・フックが同じ判定を使う。
* 良い点：`$HOME` と決め打ちせず、ユーザーの層の置き場所と比べるので、`WORKFLOW_USER_DIR` を変えても成り立つ。
* 悪い点：パスを解く処理が、そのたびに走る。

### 読む側だけを直し、書く側は今のままにする

* 良い点：変更が小さい。
* 悪い点：書く側がユーザーの層のファイルに書き、導入したリポジトリのすべてに効く。案内も食い違う。

### ホームのリポジトリかを `$HOME` との一致で判定する

* 良い点：分かりやすい。
* 悪い点：`WORKFLOW_USER_DIR` で置き場所を変えた環境では、チームの設定とユーザーの層が同じ場所になるのに、見分けられない。

## 補足

* 出典：Issue #231、[ADR 000219（プラグインが効く範囲）](000219-limit-scope-to-set-up-repos.md)・[ADR 000219（guard-git の対象のリポジトリ）](000219-resolve-guard-git-target-repo.md)、設計書 §1「効く範囲」
* 過去の ADR は編集しない決まりなので、ADR 000219 への追記ではなく、この ADR で 000219 の「導入したリポジトリ」の判定を補う。
