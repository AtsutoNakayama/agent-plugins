#!/usr/bin/env bats
# スキル（SKILL.md）の書き方を確かめる。

load test_helper

SKILLS="$BATS_TEST_DIRNAME/../plugins/dev-workflow/skills"
# 独自の観点をレビューする agent（review スキルが起動する）
AGENT="$BATS_TEST_DIRNAME/../plugins/dev-workflow/agents/perspective-reviewer.md"

# 使い方: frontmatter <SKILL.md> → 先頭の --- で囲まれた部分
frontmatter() { awk 'NR == 1 && $0 == "---" { on = 1; next } on && $0 == "---" { exit } on' "$1"; }

# 使い方: step <SKILL.md> <番号> [終わりの見出しの正規表現] → 「### <番号>.」の節の本文
# （次の「## 」か「### 」の見出しの前まで。「#### 」の見出しでは終わらない。終わりの見出しを渡すと、その見出しでも終わる）
step() { awk -v n="$2" -v end="$3" 'on && ($0 ~ /^###? / || (end != "" && $0 ~ end)) { exit } $0 ~ ("^### " n "[.]") { on = 1; next } on' "$1"; }

@test "どのスキルにも name（ディレクトリ名と同じ）と description がある" {
  for f in "$SKILLS"/*/SKILL.md; do
    name="$(basename "$(dirname "$f")")"
    assert_equal "$(frontmatter "$f" | sed -n 's/^name: //p')" "$name"
    [ -n "$(frontmatter "$f" | sed -n 's/^description: //p')" ] || fail "$name に description がありません"
  done
}

@test "どのスキルも自動で呼べる（disable-model-invocation を付けない）" {
  for f in "$SKILLS"/*/SKILL.md; do
    if frontmatter "$f" | grep -q '^disable-model-invocation:'; then
      fail "$(basename "$(dirname "$f")") に disable-model-invocation があります（外部に影響する前は確認を取る方針。設計書 §8）"
    fi
  done
}

@test "task-start・task-status・task-finish は実行の確認を取らずに進める（ワークツリーを作るかと、PR の無いタスクを閉じるかだけは聞く。設計書 §8・ADR 000162）" {
  for name in task-start task-status task-finish; do
    f="$SKILLS/$name/SKILL.md"
    if grep -n -e '承認' -e '--dry-run' "$f"; then
      fail "${name} に実行の承認や dry-run の手順があります（依頼で結果が決まるので確認を取らない）"
    fi
    grep -q '確認を取らない' "$f" || fail "${name} に「確認を取らない」と書かれていません"
  done
}

@test "確認を残すスキルに、選択肢の説明の書き方がある（設計書 §8）" {
  for name in task-create task-cancel pr-create repo-setup branch-update pr-respond task-start task-finish; do
    f="$SKILLS/$name/SKILL.md"
    grep -q '選択肢の説明には、選ぶと実際に何が起きるか' "$f" \
      || fail "${name} に選択肢の説明の書き方（選ぶと何が起きるかを書く）がありません"
    grep -q '内部の手順は書かない' "$f" \
      || fail "${name} に「内部の手順は書かない」と書かれていません"
  done
}

@test "確認を残すスキルは、確認に必要な内容を質問の中にも入れる（設計書 §8）" {
  for name in task-create task-cancel pr-create repo-setup review review-perspective-add task-finish branch-update pr-respond task-start; do
    f="$SKILLS/$name/SKILL.md"
    grep -q '質問の中にも入れる' "$f" \
      || fail "${name} に、確認に必要な内容を質問の中にも入れることが書かれていません（別の端末から使うと、質問の直前の文章が見えない）"
  done
}

@test "観点の追加・修正は、きっかけになったタスクの PR に含める（設計書 §7）" {
  f="$SKILLS/review-perspective-add/SKILL.md"
  grep -q '今のタスクのワークツリー' "$f" \
    || fail "review-perspective-add に、リポジトリの層の観点を今のタスクのワークツリーに作ることが書かれていません"
  grep -q 'work_branch' "$f" \
    || fail "review-perspective-add に、作業用のブランチの上でないときに伝えることが書かれていません"
  grep -q 'きっかけになったタスクの PR に含める' "$BATS_TEST_DIRNAME/../plugins/dev-workflow/review/issue-requirements.md" \
    || fail "issue-requirements に、観点の追加・修正を範囲外として指摘しないことが書かれていません"
}

@test "Issue の番号を取るスキルは、引数で番号を受け取れる（設計書 §8）" {
  for name in task-start task-status task-finish task-cancel; do
    f="$SKILLS/$name/SKILL.md"
    frontmatter "$f" | grep -q '^argument-hint: .*Issue番号' \
      || fail "${name} の frontmatter に argument-hint（Issue番号）がありません"
    grep -q '引数があれば' "$f" || fail "${name} に、引数の Issue の番号の扱い（引数があれば…）が書かれていません"
    grep -qF "\`#12\`" "$f" || fail "${name} に、12 と #12 のどちらも受けることが書かれていません"
  done
}

@test "task-create は、親と子をまとめて起票する手順（木の preview・親は Story Point なし・親から先に起票）を持つ" {
  f="$SKILLS/task-create/SKILL.md"
  grep -q '親と子をまとめて起票するとき' "$f" || fail "親と子をまとめて起票する手順がありません"
  grep -q '親子の木と各 Issue の本文の全文' "$f" || fail "確認の preview に親子の木と本文を入れることが書かれていません"
  grep -q '親には Story Point を付けず、子にだけ付ける' "$f" || fail "親に Story Point を付けないことが書かれていません"
  grep -q '既にある Issue を親にする' "$f" || fail "既存の Issue を親にする場合が書かれていません"
  grep -q '大きな依頼を、詰めたり縦に切ったりして子に分ける手法そのものは、この手順の範囲外' "$f" || fail "大きな依頼の分割の手法が範囲外であることが書かれていません"
  grep -q -e '--parent <親の番号>' "$f" || fail "子を --parent で起票する手順がありません"
  grep -q '新しい親なら、先に' "$f" || fail "親から先に起票する手順がありません"
  grep -q '親が閉じていれば' "$f" || fail "閉じた親の扱いが書かれていません"
  grep -q 'サブ Issue を読み直し' "$f" || fail "失敗後の再開で読み直す手順が書かれていません"
  grep -qF 'gh api --paginate repos/{owner}/{repo}/issues/<親の番号>/sub_issues' "$f" \
    || fail "サブ Issue を読み直す gh api に --paginate がありません（30件を超える子を取りこぼす）"
}

@test "task-create は、下書きの前に開いている Issue から重複と親の候補を探し、重複があれば起票の前に聞く" {
  f="$SKILLS/task-create/SKILL.md"
  # 手順2（下書きを作る）の中で、下書きの項目より前に探す
  step2="$(step "$f" 2 '^#### 下書きの項目')"
  grep -q '重複と親の候補を探す' <<<"$step2" || fail "手順2の最初に、重複と親の候補を探す手順がありません"
  grep -qF 'gh issue list --state open' <<<"$step2" || fail "開いている Issue を読む手順がありません"
  grep -qF 'subIssuesSummary' <<<"$step2" || fail "サブ Issue の数を、開いている Issue の一覧と一緒に読んでいません"
  grep -q 'AskUserQuestion' <<<"$step2" || fail "重複があるときにユーザーに聞く手順がありません"
  for choice in '既にある Issue で進める' '重ならない部分だけを起票する' 'そのまま起票する' '既にある Issue を親にする'; do
    grep -q "$choice" <<<"$step2" || fail "重複があるときの選択肢「${choice}」がありません"
  done
  grep -q '親の候補は、重なりとして数えない' <<<"$step2" || fail "指定された親と親の候補を、重なりから外すことが書かれていません"
  grep -q 'サブ Issue を既に持つ Issue.*だけを候補にする' <<<"$step2" \
    || fail "親の候補が、サブ Issue を持つ仕様の Issue に限られていません（作業の Issue を親にすると Story Point が消える）"
  grep -q 'サブ Issue を持たない Issue は.*重なりとして扱う' <<<"$step2" \
    || fail "サブ Issue を持たない広い Issue を重なりとして扱うことが書かれていません"
  grep -q '明らかな親' "$f" && fail "親の候補が、探した結果ではなく「明らかな親」のままです"
  step3="$(step "$f" 3)"
  grep -q '手順2で探した結果' <<<"$step3" || fail "手順3の確認に、探した結果がありません"
}

@test "task-next は読み取り専用（確認を取らず、Issue や列を変えるスクリプトを呼ばない。設計書 §8）" {
  f="$SKILLS/task-next/SKILL.md"
  grep -q 'next-tasks.sh' "$f" || fail "task-next が next-tasks.sh を使っていません"
  if grep -n -e 'AskUserQuestion' -e 'status-set.sh' -e 'task-start.sh' -e 'issue-create.sh' -e 'issue-cancel.sh' "$f"; then
    fail "task-next に、確認や書き込みのスクリプトがあります（何も変えない読み取り専用）"
  fi
}

@test "task-next は、親の Issue を候補に入れず、開いている子を案内する（設計書 §4）" {
  # 親の Issue に着手したセッションが、親として進めるか子に着手し直すかを聞いて止まった（#142）
  f="$SKILLS/task-next/SKILL.md"
  grep -q "\`parent\`" "$f" || fail "出力の parent の見方が書かれていません"
  grep -q '待ちでも親でもないもの' "$f" || fail "並列にできないものから、親の Issue が除かれていません"
  step2="$(step "$f" 2)"
  grep -q '\*\*親の Issue\*\*' <<<"$step2" || fail "手順2に、親の Issue の伝え方がありません"
  # 子の読み方・案内のしかたは task-start の手順2を参照し、書き写さない（孫や別のリポジトリの子の扱いがずれないように）
  grep -q 'task-start の手順2と同じように' <<<"$step2" || fail "親の子の案内が、task-start の手順2を参照していません"
  grep -q 'subIssues' <<<"$step2" && fail "task-start の手順2の、子の読み方を書き写しています"
  grep -q '親を閉じる' <<<"$step2" || fail "開いている子が無い親を閉じるよう伝えることが書かれていません"
  # task-start の手順2に、参照する内容（子の読み方・孫・別のリポジトリの子）がある
  start2="$(step "$SKILLS/task-start/SKILL.md" 2)"
  grep -q 'subIssues' <<<"$start2" || fail "task-start の手順2に、子の読み方がありません"
  grep -q '孫を案内' <<<"$start2" || fail "task-start の手順2に、孫の案内がありません"
  grep -q '別のリポジトリの子' <<<"$start2" || fail "task-start の手順2に、別のリポジトリの子の扱いがありません"
}

@test "review は、局所の指摘でも水平展開の要否を判定し、反映のときに同じ場所も直す（設計書 §7）" {
  f="$SKILLS/review/SKILL.md"
  grep -q '水平展開の要否' "$f" || fail "手順4に水平展開の要否の判定がありません"
  grep -q '局所の指摘でも' "$f" || fail "局所の指摘でも水平展開を判定することが書かれていません"
  grep -q '同じ誤りが残っていれば' "$f" || fail "同じ誤りが残る場所を一覧に加えることが書かれていません"
  # 手順6（反映する）の中に、水平展開の場所を直すことと再検索がある
  step6="$(step "$f" 6)"
  grep -q '水平展開' <<<"$step6" || fail "手順6に、水平展開の場所を直すことがありません"
  grep -q '同じ検索' <<<"$step6" || fail "手順6に、直した後の再検索がありません"
}

@test "review は、終えるときに見落としの指摘と今後も要らない指摘を観点に残すかを尋ねる（設計書 §7）" {
  f="$SKILLS/review/SKILL.md"
  step9="$(step "$f" 9)"
  [ -n "$step9" ] || fail "手順9（観点に残すか確かめる）がありません"
  grep -q '見落とし' <<<"$step9" || fail "見落としの指摘を拾うことが書かれていません"
  grep -q '今後も要らない指摘' <<<"$step9" || fail "今後も要らない指摘を拾うことが書かれていません"
  grep -q '一般的なバグ' <<<"$step9" || fail "一般的なバグを対象にしないことが書かれていません"
  grep -q 'その場限りの好み' <<<"$step9" || fail "その場限りの好みを対象にしないことが書かれていません"
  grep -q '自動では変えない' <<<"$step9" || fail "ユーザーが選んだものだけを変えることが書かれていません"
  grep -q 'review-perspective-add' <<<"$step9" || fail "review-perspective-add の手順で作ることが書かれていません"
  grep -q '既にある観点' <<<"$step9" || fail "既にある観点を直す案が書かれていません"
  grep -q '「〜を指摘しない」だけの観点は新しく作らない' <<<"$step9" || fail "指摘しないだけの観点を作らないことが書かれていません"
  grep -q -- '--builtin code-review' <<<"$step9" || fail "code-review の除外を上位の層に作ることが書かれていません"
  # 周回を終える出口（手順8）と、指摘が無い・何も選ばれないときの終わり方が、手順9へ進む
  step8="$(step "$f" 8)"
  grep -q '手順9へ進む' <<<"$step8" || fail "手順8で終えるときに手順9へ進むことが書かれていません"
  [ "$(grep -c '手順9へ進む' "$f")" -ge 3 ] || fail "手順4・5の終わり方が手順9へ進んでいません"
  # /code-review の指摘は、code-review の観点ファイルの「指摘しないこと」で外す
  step4="$(step "$f" 4)"
  grep -q '## 指摘しないこと' <<<"$step4" || fail "手順4で /code-review の指摘を除外の決まりと照らすことが書かれていません"
  grep -q '外した件数' <<<"$step4" || fail "外した件数を伝えることが書かれていません"
  # 同梱の code-review.md 自体には、除外の節を書かない（書くと全員の指摘が外れる）
  grep -q '^## 指摘しないこと' "$BATS_TEST_DIRNAME/../plugins/dev-workflow/review/code-review.md" \
    && fail "同梱の code-review.md に除外の節があります"
  grep -q 'dev-workflow:review` の手順9（観点に残すか確かめる）' "$BATS_TEST_DIRNAME/../plugins/dev-workflow/defaults/task-flow.md" \
    || fail "SessionStart の流れ（defaults/task-flow.md）に、レビューの後の指摘を観点に残すことがありません"
  grep -q '「〜を指摘しない」ことだけを書いた観点は作らない' "$SKILLS/review-perspective-add/SKILL.md" \
    || fail "review-perspective-add に、指摘しないだけの観点を作らないことが書かれていません"
}

@test "不具合の修正の手順に、同じ原因の他の箇所を探すことがある（CONTRIBUTING・task-flow・設計書）" {
  grep -q '同じ原因の他の箇所' "$BATS_TEST_DIRNAME/../CONTRIBUTING.md" || fail "CONTRIBUTING のテストのルールにありません"
  grep -q '同じ原因の他の箇所' "$BATS_TEST_DIRNAME/../plugins/dev-workflow/defaults/task-flow.md" || fail "SessionStart の流れ（defaults/task-flow.md）にありません"
  grep -q '同じ原因の他の箇所を' "$BATS_TEST_DIRNAME/../docs/design.md" || fail "設計書にありません"
}

@test "task-finish は、別のリポジトリの Issue の確認・クローズに --repo を付けて案内する" {
  f="$SKILLS/task-finish/SKILL.md"
  grep -q 'gh issue view <番号>' "$f"
  grep -q 'gh issue close <番号>' "$f"
  # shellcheck disable=SC2016 # バッククォートはスキルの本文の文字で、展開させない
  grep -q 'どちらのコマンドにも `--repo <owner/repo>` を付けて案内する' "$f"
}

@test "task-start は、ワークツリーを作るかを本文から判断して提案し、作らないなら --no-worktree で着手する（設計書 §4）" {
  f="$SKILLS/task-start/SKILL.md"
  grep -q 'ワークツリーを作って着手する' "$f" || fail "作って着手する選択肢がありません"
  grep -q 'ワークツリーを作らずに着手する' "$f" || fail "作らずに着手する選択肢がありません"
  grep -q 'task-start.sh --issue <番号> --no-worktree' "$f" || fail "作らないときの実行のしかたがありません"
}

# shellcheck disable=SC2016 # バッククォートはスキルの本文の文字で、展開させない
@test "ワークツリーの無いタスクを、task-finish は Issue を閉じて終え、task-cancel は Issue を閉じるだけにする" {
  grep -q '### 4. ワークツリーの無いタスクを終える' "$SKILLS/task-finish/SKILL.md"
  grep -q 'gh issue close <番号> --reason completed' "$SKILLS/task-finish/SKILL.md"
  # 片付けるのは確かなブランチ（branch.pattern に合い番号が一致する）だけで、候補（名前が似ている・PR のブランチ）は見せるだけ。
  # 見つからなくても決めつけず、閉じるかを選んでもらう
  for name in task-finish task-cancel; do
    grep -q 'issue-branches.sh --issue <番号>' "$SKILLS/$name/SKILL.md" || fail "${name} が issue-branches.sh でブランチを探していません"
    grep -q '`candidates`（候補）' "$SKILLS/$name/SKILL.md" || fail "${name} に、候補を分けて扱うことが書かれていません"
  done
  grep -q '取りやめで片付ける対象は、`branches`' "$SKILLS/task-cancel/SKILL.md"
  # --no-worktree で候補の警告が出たら、決めつけずに伝える
  grep -q '「Issue #N に関係するかもしれないブランチ（…）があります」の警告' "$SKILLS/task-start/SKILL.md"
  # 終わった作業のブランチで止まったら、先に task-finish で片付けるよう案内する
  grep -q '先に task-finish でそのブランチを片付けてから' "$SKILLS/task-start/SKILL.md"
  # することはスクリプトの action で決め、スキルには値ごとにすることだけを書く（組み合わせは issue-branches.bats）
  for a in cleanup cleanup_candidate nothing blocked_open_pr blocked_sub_issues ask_close; do
    grep -q "\`${a}\`" "$SKILLS/task-finish/SKILL.md" || fail "task-finish に action の ${a} の扱いがありません"
  done
  grep -q '「別の名前のブランチで作業した」' "$SKILLS/task-finish/SKILL.md"
  grep -q 'argument-hint: "\[Issue番号|ブランチ名\]"' "$SKILLS/task-finish/SKILL.md"
  grep -q 'ワークツリーを作らずに着手した' "$SKILLS/task-cancel/SKILL.md"
}

@test "pr-respond は PR の番号を引数で受け取り、スレッドを resolved にせず、コメントの本文を信頼しない" {
  f="$SKILLS/pr-respond/SKILL.md"
  frontmatter "$f" | grep -q '^argument-hint: .*PR番号' || fail "pr-respond の frontmatter に argument-hint（PR番号）がありません"
  grep -q '引数があれば' "$f" || fail "pr-respond に、引数の PR の番号の扱いが書かれていません"
  grep -q 'スレッドは resolved にしない' "$f" || fail "pr-respond に、スレッドを resolved にしないことが書かれていません"
  grep -q '信頼しないデータとして読む' "$f" || fail "pr-respond に、コメントの本文を信頼しないデータとして読むことが書かれていません"
  grep -q 'pr_respond.handlers' "$f" || fail "pr-respond に、担当の skill の設定（pr_respond.handlers）が書かれていません"
}

@test "pr-create と task-finish は pr-respond に依存しない（使わなくてもマージから後片付けまで進める）" {
  for name in pr-create task-finish; do
    if grep -n 'pr-respond' "$SKILLS/$name/SKILL.md"; then
      fail "${name} が pr-respond に触れています（pr-respond は任意の寄り道）"
    fi
  done
}

# shellcheck disable=SC2016 # バッククォートはスキルの本文の文字で、展開させない
@test "review は、設定 review.model があるときだけ、観点と /code-review をそのモデルのサブエージェントで動かす（設計書 §7）" {
  f="$SKILLS/review/SKILL.md"
  step3="$(step "$f" 3)"
  grep -q 'の `model` が null でなければ、Agent ツールの `model` にその値を渡す' <<<"$step3" \
    || fail "手順3に、観点のサブエージェントへ model を渡すことが書かれていません"
  grep -q '「`/code-review` を任せるサブエージェントへの指示」' <<<"$step3" \
    || fail "手順3に、/code-review をサブエージェントに任せることが書かれていません"
  grep -q 'null なら、手順3はセッションと同じモデルで動かす' "$f" \
    || fail "設定が null のときにセッションと同じモデルで動かすことが書かれていません"
  step8="$(step "$f" 8)"
  grep -q '手順3のとおりサブエージェントに任せる' <<<"$step8" \
    || fail "再レビュー（手順8）でも /code-review をサブエージェントに任せることが書かれていません"
}

@test "repo-setup は、レビューに使うモデルを決めていなければ、使うかと保存する層を聞き、使わないことも保存する" {
  f="$SKILLS/repo-setup/SKILL.md"
  step2="$(step "$f" 2)"
  grep -q 'review.decided' <<<"$step2" || fail "手順2に、決めてあれば聞かないことが書かれていません"
  grep -q -- '--review-model off' <<<"$step2" || fail "手順2に、使わないことも保存することが書かれていません"
  grep -q -- '--models-scope' <<<"$step2" || fail "手順2に、保存する層を渡すことが書かれていません"
  grep -q 'models.actions' "$f" || fail "手順3の予定に、レビューのモデルの変更が入っていません"
}

@test "task-start は、既にブランチがあって --no-worktree が止まったら、そのワークツリーで作業するよう案内する" {
  grep -q '「Issue #N には既にブランチ … があります」で止まったら' "$SKILLS/task-start/SKILL.md"
}

@test "「変更するファイル・領域」の書き方に、ファイルを変えないタスクの「なし」がある（task-create・Issue テンプレート・task-start）" {
  grep -q 'リポジトリのファイルを変えないタスクなら「- なし」と書く' "$SKILLS/task-create/SKILL.md"
  for f in "$BATS_TEST_DIRNAME/../plugins/dev-workflow/templates/ISSUE_TEMPLATE/task.md" "$BATS_TEST_DIRNAME/../.github/ISSUE_TEMPLATE/task.md"; do
    grep -q 'リポジトリのファイルを変えないタスクなら「なし」と書きます' "$f" || fail "$f に「なし」の書き方がありません"
  done
  grep -q '「変更するファイル・領域」が「- なし」なら、変えないタスクとして書かれている' "$SKILLS/task-start/SKILL.md"
}

@test "README に、ワークツリーの要らないタスクの流れと、task-finish にブランチ名を渡せることが書いてある" {
  readme="$BATS_TEST_DIRNAME/../README.md"
  grep -q 'リポジトリのファイルを変えないタスクの流れ（ワークツリーを作らずに着手し' "$readme" || fail "タスクの進め方に、ワークツリーの要らない流れがありません"
  # shellcheck disable=SC2016 # バッククォートは README の文字で、展開させない
  grep -q '`task-finish` は、`/dev-workflow:task-finish fix-typo` のように、番号の代わりにブランチ名も渡せます' "$readme" || fail "引数の説明に、task-finish のブランチ名がありません"
}

# shellcheck disable=SC2016 # バッククォートはスキルの本文の文字で、展開させない
@test "review は、独自の観点をプラグインの agent（ファイルを編集するツールを持たない）でレビューする（設計書 §7）" {
  [ -f "$AGENT" ] || fail "agents/perspective-reviewer.md がありません"
  assert_equal "$(frontmatter "$AGENT" | sed -n 's/^name: //p')" "perspective-reviewer"
  tools="$(frontmatter "$AGENT" | sed -n 's/^tools: //p')"
  assert_equal "$tools" "Read, Grep, Glob, Bash"
  rule="$(grep '1つずつ実行し' "$AGENT")" || fail "agent の定義に、Bash のコマンドを1つずつ実行する決まりがありません（つなぐと承認されないことがある）"
  for w in '`cd`' '`&&`' '`;`' '`|`'; do
    grep -qF "$w" <<<"$rule" || fail "agent の、Bash のコマンドを1つずつ実行する決まりに ${w} がありません"
  done
  grep -q '観点ファイルがつないだコマンド.*1つずつに分けて' "$AGENT" \
    || fail "agent の定義に、観点ファイルがつないだコマンドを指示したときの扱いがありません"
  grep -q '1つずつのコマンドで確かめられなければ.*`notes`' "$AGENT" \
    || fail "agent の定義に、分けて確かめられないときに notes に書くことがありません"

  f="$SKILLS/review/SKILL.md"
  step3="$(step "$f" 3)"
  grep -q 'subagent_type.*dev-workflow:perspective-reviewer' <<<"$step3" \
    || fail "手順3に、独自の観点を subagent_type で agent に任せることが書かれていません"
  step8="$(step "$f" 8)"
  grep -q 'dev-workflow:perspective-reviewer' <<<"$step8" \
    || fail "再レビュー（手順8）で、独自の観点を agent で起動することが書かれていません"
}

# shellcheck disable=SC2016 # バッククォートはスキルの本文の文字で、展開させない
@test "perspective-reviewer は findings と notes の1つの形で返し、review はどの部分も捨てずに読んで、伝言を手順4・5・7・8で伝える（設計書 §7）" {
  grep -q '{"findings": ' "$AGENT" || fail "agent の定義に、findings と notes の形がありません"
  grep -q '"suggestion"' "$AGENT" || fail "agent の定義に、指摘の項目（file・line・summary・detail・suggestion）がありません"
  grep -q '`notes`' "$AGENT" || fail "agent の定義に、notes の説明がありません"
  grep -q '問題は `notes` に書かない' "$AGENT" \
    || fail "agent の定義に、問題を notes に入れない決まりがありません（伝言は番号が付かず選べない）"
  grep -q 'とだけ返す」と決めていても' "$AGENT" \
    || fail "agent の定義に、観点ファイルが返し方を決めていても形を変えない決まりがありません"
  f="$SKILLS/review/SKILL.md"
  if grep -n '"suggestion"' "$f"; then
    fail "review の SKILL.md に、返す JSON の形式が残っています（agent の定義だけに書く）"
  fi
  step3="$(step "$f" 3)"
  grep -q '囲まれていたり、前置き' <<<"$step3" \
    || fail "手順3に、囲みや前置きがあっても返事の JSON を読むことが書かれていません"
  grep -q '包まれていない配列.*`file` と `summary` を持つときだけ' <<<"$step3" \
    || fail "手順3に、包まれていない配列を、指摘の形のときだけ読むことが書かれていません"
  grep -q '配列の各項目を、手順4の一覧' <<<"$step3" \
    || fail "手順3に、findings を一覧の指摘にすることが書かれていません"
  grep -q '`notes` と、指摘として読まなかった部分.*伝言' <<<"$step3" \
    || fail "手順3に、notes と指摘として読まなかった部分を伝言にすることが書かれていません"
  grep -q '読めない返事は、指摘にはせず' <<<"$step3" \
    || fail "手順3に、オブジェクトを読めない返事の扱いが書かれていません"
  grep -q '伝言は、観点の名前を添えて' <<<"$step3" \
    || fail "手順3に、伝言の伝え方（観点の名前を添える）が書かれていません"
  step4="$(step "$f" 4)"
  grep -q '^- 指摘が1つも無ければ.*観点からの伝言' <<<"$step4" \
    || fail "手順4の、指摘が無いときに伝えることに、観点からの伝言が入っていません"
  grep -q '^- 表の後に.*観点からの伝言' <<<"$step4" \
    || fail "手順4の、表の後に添えることに、観点からの伝言が入っていません"
  step5="$(step "$f" 5)"
  grep -q '観点からの伝言.*質問の中にも入れる' <<<"$step5" \
    || fail "手順5に、観点からの伝言を質問の中に入れることが書かれていません"
  step7="$(step "$f" 7)"
  grep -q 'これまでの周の観点からの伝言' <<<"$step7" \
    || fail "手順7に、観点からの伝言を改めて伝えることが書かれていません"
  grep -q '前の周の伝言は.*どの手順から手順9へ進むときも' <<<"$step3" \
    || fail "手順3に、レビューを終えるときに前の周の伝言もまとめて伝えることが書かれていません"
  step8="$(step "$f" 8)"
  grep -q '^1\. \*\*今の周が上限に達していて.*これまでの周の観点からの伝言' <<<"$step8" \
    || fail "手順8の上限の周の質問に、観点からの伝言が入っていません"
  grep -q '^- 新しい指摘が無ければ.*手順4' <<<"$step8" \
    || fail "手順8の、新しい指摘が無いときに、手順4のとおり伝えることが書かれていません"
}

@test "観点ファイルは結果の形を書かず、review-perspective-add は結果の形を決める agent を案内する（設計書 §7）" {
  # 結果の形（findings と notes）は agent perspective-reviewer が決める。観点ファイルが返し方を書くと、agent の決まりと食い違う
  # 「[] を返す」「JSON で返す」「とだけ返す」は拾い、「gh が返す JSON」のような文は拾わない
  if grep -nE '(を|で|と|だけ)返す' "$BATS_TEST_DIRNAME/../plugins/dev-workflow/review/"*.md; then
    fail "同梱の観点ファイルに、返し方が書かれています（「〜と伝える」と書けば notes で伝わる）"
  fi
  grep -q 'agents/perspective-reviewer.md' "$SKILLS/review-perspective-add/SKILL.md" \
    || fail "review-perspective-add に、結果の形を決めるのが agent perspective-reviewer だと書かれていません"
}

@test "task-create は、導入したリポジトリでの分け方の提案でも呼ばれ、起票を頼まれていなければ起票せずに止められる（#169）" {
  f="$SKILLS/task-create/SKILL.md"
  frontmatter "$f" | grep -qF 'dev-workflow を導入したリポジトリで Issue の分け方・親子の構成を提案するときに使う' \
    || fail "description に、導入したリポジトリでの分け方の提案が書かれていません"
  # 相談のときの違いは1つの節にまとめ、手順の中に書き分けない（書き分けると、手順の間の継ぎ目が抜けるため）
  consult="$(awk '$0 == "## 起票を頼まれていない相談で呼ばれたとき" { on = 1; next } on && /^## / { exit } on' "$f")"
  [ -n "$consult" ] || fail "相談で呼ばれたときの節がありません"
  # shellcheck disable=SC2016 # バッククォートは SKILL.md の本文の文字で、展開させない
  grep -qF '手順1で読んだ `detected.set_up` が false なら、このスキルを使わずに止める' <<<"$consult" || fail "相談の節に、導入していなければ止めることが書かれていません"
  grep -qF 'ラベルと説明を「起票する」ではなく「下書きする」と書く' <<<"$consult" || fail "相談の節に、選択肢の書き方がありません"
  grep -qF '「起票しない（提案だけにする）」を足し、選ばれたら起票せずに止める' <<<"$consult" || fail "相談の節に、提案だけで止めることが書かれていません"
  for n in 1 2 3 4; do
    if step "$f" "$n" | grep -n -e '相談で呼ばれて' -e '相談では' -e 'この検索を飛ばし'; then
      fail "手順${n}に、相談のときの書き分けがあります（相談の節にまとめる）"
    fi
  done
  # 導入したかは、フックと同じ判定（dw_is_set_up）を出す config.sh の detected.set_up で決め、設定ファイルを自分で探さない
  # shellcheck disable=SC2016 # バッククォートは SKILL.md の本文の文字で、展開させない
  step "$f" 1 | grep -qF '`detected.set_up`：リポジトリが dev-workflow を導入しているか' || fail "手順1に、detected.set_up で導入を判定することが書かれていません"
  # shellcheck disable=SC2016 # バッククォートは SKILL.md の本文の文字で、展開させない
  step "$f" 1 | grep -qF '`config.sh` が失敗したら、標準エラーの1行のメッセージを伝えて止める' || fail "手順1に、config.sh が失敗したら止めることが書かれていません"
  # 分け方の案は、相談・親と子をまとめて起票する依頼・独立した作業を含む依頼でだけ下書きする（SP が大きいだけなら手順3の分割の提案）
  draft="$(step "$f" 2 '^#### 親と子をまとめて')"
  grep -qF '分け方の相談で呼ばれたときと、親と子をまとめて起票する依頼か、独立して着手できる作業をいくつも含む依頼で' <<<"$draft" \
    || fail "下書きの項目に、分け方の案を下書きする場合が書かれていません"
  grep -qF '1本に収まる普通の依頼は、分け方を聞かずに1つの Issue として下書きする' <<<"$draft" || fail "下書きの項目に、普通の依頼では分け方を聞かないことが書かれていません"
  grep -qF 'Story Point が 21 以上になりそうなだけのときは、ここでは分けず、手順3の分割の提案' <<<"$draft" || fail "下書きの項目に、SP が大きいだけのときの扱いが書かれていません"
  # 分けた Issue も、依頼全体と同じ決まり（親の候補・重なりの質問）で照らす
  grep -qF '分けた Issue ごとにも、上の「重複と親の候補を探す」と同じ決まりで' <<<"$draft" || fail "下書きの項目に、分けた Issue の重なりを確かめることが書かれていません"
  grep -qF '重複・重なりがあれば、同じ質問でどうするかを聞いてから' <<<"$draft" || fail "下書きの項目に、分けた Issue の重なりを質問で聞くことが書かれていません"
  # 重複と親の候補は、相談でも下書きの前に探す（下書きの前提なので、延ばさない）
  step "$f" 2 | grep -qF '重複と親の候補は、起票を頼まれていない相談で呼ばれたときも、同じように下書きの前に探す' \
    || fail "手順2に、相談でも下書きの前に重複と親の候補を探すことが書かれていません"
}
