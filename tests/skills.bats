#!/usr/bin/env bats
# スキル（SKILL.md）の書き方を確かめる。

load test_helper

SKILLS="$BATS_TEST_DIRNAME/../plugins/dev-workflow/skills"

# 使い方: frontmatter <SKILL.md> → 先頭の --- で囲まれた部分
frontmatter() { awk 'NR == 1 && $0 == "---" { on = 1; next } on && $0 == "---" { exit } on' "$1"; }

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

@test "task-start・task-status・task-finish は実行の確認を取らずに進める（設計書 §8）" {
  for name in task-start task-status task-finish; do
    f="$SKILLS/$name/SKILL.md"
    if grep -n -e '承認' -e '--dry-run' "$f"; then
      fail "${name} に実行の承認や dry-run の手順があります（依頼で結果が決まるので確認を取らない）"
    fi
    grep -q '確認を取らない' "$f" || fail "${name} に「確認を取らない」と書かれていません"
  done
}

@test "確認を残すスキルに、選択肢の説明の書き方がある（設計書 §8）" {
  for name in task-create task-cancel pr-create repo-setup branch-update; do
    f="$SKILLS/$name/SKILL.md"
    grep -q '選択肢の説明には、選ぶと実際に何が起きるか' "$f" \
      || fail "${name} に選択肢の説明の書き方（選ぶと何が起きるかを書く）がありません"
    grep -q '内部の手順は書かない' "$f" \
      || fail "${name} に「内部の手順は書かない」と書かれていません"
  done
}

@test "確認を残すスキルは、確認に必要な内容を質問の中にも入れる（設計書 §8）" {
  for name in task-create task-cancel pr-create repo-setup review review-perspective-add task-finish branch-update; do
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
  grep -q '大きな依頼を、詰めたり縦に切ったりして子に分けるところは、この手順の範囲外' "$f" || fail "大きな依頼の分割が範囲外であることが書かれていません"
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
  step2="$(awk '/^### 2\./ { on = 1; next } /^#### 下書きの項目/ { on = 0 } on' "$f")"
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
  step3="$(awk '/^### 3\./ { on = 1; next } /^### 4\./ { on = 0 } on' "$f")"
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
  step2="$(awk '/^### 2\./ { on = 1; next } on' "$f")"
  grep -q '\*\*親の Issue\*\*' <<<"$step2" || fail "手順2に、親の Issue の伝え方がありません"
  grep -q 'subIssues' <<<"$step2" || fail "親の開いている子を読む手順がありません"
  grep -q '親を閉じる' <<<"$step2" || fail "開いている子が無い親を閉じるよう伝えることが書かれていません"
}

@test "review は、局所の指摘でも水平展開の要否を判定し、反映のときに同じ場所も直す（設計書 §7）" {
  f="$SKILLS/review/SKILL.md"
  grep -q '水平展開の要否' "$f" || fail "手順4に水平展開の要否の判定がありません"
  grep -q '局所の指摘でも' "$f" || fail "局所の指摘でも水平展開を判定することが書かれていません"
  grep -q '同じ誤りが残っていれば' "$f" || fail "同じ誤りが残る場所を一覧に加えることが書かれていません"
  # 手順6（反映する）の中に、水平展開の場所を直すことと再検索がある
  step6="$(awk '/^### 6\./ { on = 1; next } /^### 7\./ { on = 0 } on' "$f")"
  grep -q '水平展開' <<<"$step6" || fail "手順6に、水平展開の場所を直すことがありません"
  grep -q '同じ検索' <<<"$step6" || fail "手順6に、直した後の再検索がありません"
}

@test "review は、終えるときに見落としの指摘と今後も要らない指摘を観点に残すかを尋ねる（設計書 §7）" {
  f="$SKILLS/review/SKILL.md"
  step9="$(awk '/^### 9\./ { on = 1; next } on' "$f")"
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
  step8="$(awk '/^### 8\./ { on = 1; next } /^### 9\./ { on = 0 } on' "$f")"
  grep -q '手順9へ進む' <<<"$step8" || fail "手順8で終えるときに手順9へ進むことが書かれていません"
  [ "$(grep -c '手順9へ進む' "$f")" -ge 3 ] || fail "手順4・5の終わり方が手順9へ進んでいません"
  # /code-review の指摘は、code-review の観点ファイルの「指摘しないこと」で外す
  step4="$(awk '/^### 4\./ { on = 1; next } /^### 5\./ { on = 0 } on' "$f")"
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
