#!/usr/bin/env bash
# 直前のコミット（HEAD^）から HEAD までの変更が、ドキュメントだけかを調べる。Lint・Test が重いジョブを飛ばすかの判断に使う。
# マージキュー（GITHUB_EVENT_NAME が merge_group）では、キューの先頭側のコミット（環境変数 MERGE_GROUP_BASE_SHA、
# ワークフローが merge_group.base_sha を渡す）から HEAD までを見る。キュー用のブランチのコミットの形に頼って HEAD^ を使うと、
# PR が複数のコミットのときに、最後の1つだけを見てしまうおそれがあるため。
# 移動（rename）は、移動元も変更として見る（--no-renames）。tests/ から docs/ へ移したのに、移動先だけを見てドキュメントだけと判断しないため。
# 出力: {"docs_only": true|false}。調べられないとき（親が無い・git が失敗）は false にして、CI を動かす側に倒す。
#
# ここで「ドキュメント」とするのは、プラグインの外にある次のファイルだけ。**.md でまとめて除外しないのは、
# plugins/ の SKILL.md やテンプレートの .md をテストで使っているため。
#   README.md、docs/ の下、.github/ISSUE_TEMPLATE/ の下、.github/pull_request_template.md
# .github/workflows/ の下は入れない（ワークフローを変えた PR で actionlint を動かすため）。
set -euo pipefail

base=HEAD^
if [ "${GITHUB_EVENT_NAME:-}" = merge_group ] && [ -n "${MERGE_GROUP_BASE_SHA:-}" ]; then
  base="$MERGE_GROUP_BASE_SHA"
  # 浅い取得には比較元が無いので取ってくる。取れなくても止めない。比べられなければ、下の git diff が失敗して false になる
  git fetch --no-tags --depth=1 origin "$base" >/dev/null 2>&1 || true
fi

if ! files="$(git -c core.quotepath=false diff --no-renames --name-only "$base" HEAD 2>/dev/null)"; then
  echo '{"docs_only": false}'
  exit 0
fi

# 変更が無い（空のコミット）ときも、ドキュメントだけとは言えないので false にする
docs_only=false
if [ -n "$files" ]; then
  docs_only=true
  while IFS= read -r f; do
    case "$f" in
      README.md | docs/* | .github/ISSUE_TEMPLATE/* | .github/pull_request_template.md) ;;
      *)
        docs_only=false
        break
        ;;
    esac
  done <<<"$files"
fi

echo "{\"docs_only\": $docs_only}"
