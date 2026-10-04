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
