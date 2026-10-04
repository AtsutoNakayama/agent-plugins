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
  for name in task-create task-cancel pr-create repo-setup; do
    f="$SKILLS/$name/SKILL.md"
    grep -q '選択肢の説明には、選ぶと実際に何が起きるか' "$f" \
      || fail "${name} に選択肢の説明の書き方（選ぶと何が起きるかを書く）がありません"
    grep -q '内部の手順は書かない' "$f" \
      || fail "${name} に「内部の手順は書かない」と書かれていません"
  done
}

@test "確認を残すスキルは、確認に必要な内容を質問の中にも入れる（設計書 §8）" {
  for name in task-create task-cancel pr-create repo-setup review review-perspective-add task-finish; do
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
