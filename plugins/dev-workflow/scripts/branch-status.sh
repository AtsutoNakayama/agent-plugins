#!/usr/bin/env bash
# 今のブランチ（作業用のブランチ）が、マージ先のブランチ（base_branch）より遅れているかを調べる。
# 何も変更しない（fetch だけ行う）。取り込む作業は今のブランチに対して行うので、調べるのも今のブランチだけにする。
#
# 使い方: branch-status.sh
#
# 出力（JSON）:
#   branch, base          今のブランチと、取り込み先（base_branch）
#   behind                origin/<base> にあって、ブランチに無いコミットの数
#   ahead                 ブランチにあって、origin/<base> に無いコミットの数
#   up_to_date            behind が 0 か（取り込むものが無いか）
#   conflicts             origin/<base> を取り込むと衝突するか。手元で確かめる（git merge-tree。何も変えない）ので、
#                         GitHub がマージできるかを調べている途中（merge_state が UNKNOWN）でも分かる。
#                         behind が 0 なら false。確かめられない（git が 2.38 より古いなど）ときは null
#   dirty                 未コミットの変更（追跡しているファイルの変更。未追跡のファイルと、git が無視するファイルは除く）があるか
#   unpushed              origin/<ブランチ> に無い、手元のコミットの数。origin にブランチが無ければ null
#   unpulled              手元に無い、origin/<ブランチ> のコミットの数（push が拒否される原因になる）。origin にブランチが無ければ null
#   pr                    そのブランチの開いている PR（number・url・merge_state・merge_queue）。無ければ null
#                         merge_state は GitHub の mergeStateStatus（BEHIND・DIRTY・BLOCKED・CLEAN など）。
#                         fork の同じ名前のブランチからの PR は除く。PR が無い、gh が無い、
#                         または gh で取得できないときは、pr は null になる（behind と ahead は gh が無くても出る）
#                         pr.merge_queue はマージキューの状態（enabled・state・position・removed）。enabled は PR のマージ先で
#                         キューが有効か、state・position は PR がキューに並んでいるときの状態（QUEUED・AWAITING_CHECKS・
#                         MERGEABLE・UNMERGEABLE・LOCKED）と順番（1 が先頭）で、並んでいなければ null。
#                         キューに並んだ PR は、merge_state が CLEAN でも、先に並んだ PR と衝突すると state が UNMERGEABLE になり、
#                         すぐにキューから外れる。removed は、PR がキューから外れたままのときの、外れた理由と時刻（{reason, at}。
#                         reason は GitHub の値で、衝突なら merge_conflict）。外れた後にキューへ入れ直していれば null。
#                         外れた後に push したかは見ない（理由に対応済みかは分からない）。取得できなければ merge_queue は null になる
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require jq git

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done

repo_root="$(dw_repo_root)" || dw_die "リポジトリの中で実行してください" 64
config="$("$BASH" "$DW_SCRIPTS_DIR/config.sh")"
base="$(jq -r '.base_branch' <<<"$config")"

branch="$(git -C "$repo_root" symbolic-ref --short -q HEAD || true)"
[ -n "$branch" ] || dw_die "ブランチの上にいません。取り込む作業用のブランチに切り替えてください" 64
[ "$branch" != "$base" ] || dw_die "${base} には取り込めません。作業用のブランチで実行してください" 64

git -C "$repo_root" fetch -q origin -- "$base" || dw_die "origin/${base} を取得できませんでした"
ref="refs/remotes/origin/$base"
git -C "$repo_root" show-ref --verify --quiet "$ref" || dw_die "origin/${base} がありません"

behind="$(git -C "$repo_root" rev-list --count "refs/heads/$branch..$ref")"
ahead="$(git -C "$repo_root" rev-list --count "$ref..refs/heads/$branch")"

# 取り込むと衝突するか。merge-tree は、衝突なしで 0、衝突で 1、それ以外の失敗（古い git で --write-tree が無いなど）で
# 別の値を返す。結果のツリーはオブジェクトとして書かれるだけで、作業ツリーとブランチは変わらない
conflicts=false
if [ "$behind" -gt 0 ]; then
  merge_rc=0
  git -C "$repo_root" merge-tree --write-tree --no-messages "refs/heads/$branch" "$ref" >/dev/null 2>&1 || merge_rc=$?
  case "$merge_rc" in
    0) conflicts=false ;;
    1) conflicts=true ;;
    *) conflicts=null ;;
  esac
fi

dirty=false
[ -z "$(git -C "$repo_root" status --porcelain --untracked-files=no)" ] || dirty=true

# 手元のブランチと origin のブランチのずれ。origin にブランチが無ければ null。
# ls-remote の終了コードは、ブランチが無いとき 2、通信などの失敗のときはそれ以外（0 か 2 でなければ止める）
unpushed=null unpulled=null
remote_rc=0
git -C "$repo_root" ls-remote --exit-code --heads origin "refs/heads/$branch" >/dev/null 2>&1 || remote_rc=$?
case "$remote_rc" in
  0)
    git -C "$repo_root" fetch -q origin -- "$branch" || dw_die "origin/${branch} を取得できませんでした"
    unpushed="$(git -C "$repo_root" rev-list --count "refs/remotes/origin/$branch..refs/heads/$branch")"
    unpulled="$(git -C "$repo_root" rev-list --count "refs/heads/$branch..refs/remotes/origin/$branch")"
    ;;
  2) ;;
  *) dw_die "origin に ${branch} があるかを確かめられませんでした" ;;
esac

# --head はブランチ名だけで探すので、fork の同じ名前のブランチからの PR を除く
pr=null
if command -v gh >/dev/null 2>&1 \
  && prs="$(gh pr list --head "$branch" --state open --json number,url,mergeStateStatus,isCrossRepository 2>/dev/null)"; then
  pr="$(jq -c 'map(select(.isCrossRepository | not)) | first // null | if . then {number, url, merge_state: .mergeStateStatus} else null end' <<<"$prs")"
fi

# マージキューの状態は gh pr list にも REST にも無いので GraphQL で読む（設計書 §10）。PR の URL から引くので、
# リポジトリの所有者と名前を別に調べなくてよい。取得できなければ merge_queue は null にする。
# 衝突した PR はすぐにキューから外れて mergeQueueEntry が null になるので、外れたことはタイムラインの最後の
# キューの出入りのイベントで見る。キューに並んでおらず、最後が外れたイベントなら、外れたままとみなす。
# 外れた後に push したかは見ない。GitHub には push の時刻が無く（Commit.pushedDate は廃止）、コミットの時刻
# （committedDate）は手元でコミットした時刻なので、外れる前に作ったコミットや手元の時計のずれで誤る。
# push の後でも PR はキューから外れたままなので、branch-update は、対応済みなら入れ直すよう案内する
if [ "$pr" != null ]; then
  queue=null
  # shellcheck disable=SC2016 # GraphQL の変数（$url）を bash に展開させないため、シングルクォートで書く
  if res="$(dw_gql 'query PrQueue($url: URI!) {
      resource(url: $url) {
        ... on PullRequest {
          isMergeQueueEnabled
          mergeQueueEntry { state position }
          timelineItems(itemTypes: [ADDED_TO_MERGE_QUEUE_EVENT, REMOVED_FROM_MERGE_QUEUE_EVENT], last: 1) {
            nodes { __typename ... on RemovedFromMergeQueueEvent { reason createdAt } }
          }
        }
      }
    }' "$(jq -c '{url}' <<<"$pr")" 2>/dev/null)"; then
    queue="$(jq -c '.data.resource // null | if . then
        (.timelineItems.nodes[0] // null) as $ev
        | {enabled: .isMergeQueueEnabled, state: .mergeQueueEntry.state, position: .mergeQueueEntry.position,
           removed: (if .mergeQueueEntry == null and $ev.__typename == "RemovedFromMergeQueueEvent"
                     then {reason: $ev.reason, at: $ev.createdAt} else null end)}
      else null end' <<<"$res" 2>/dev/null || echo null)"
  fi
  pr="$(jq -c --argjson q "$queue" '. + {merge_queue: $q}' <<<"$pr")"
fi

jq -n --arg branch "$branch" --arg base "$base" --argjson behind "$behind" --argjson ahead "$ahead" \
  --argjson conflicts "$conflicts" --argjson dirty "$dirty" --argjson unpushed "$unpushed" --argjson unpulled "$unpulled" --argjson pr "$pr" \
  '{branch: $branch, base: $base, behind: $behind, ahead: $ahead, up_to_date: ($behind == 0), conflicts: $conflicts, dirty: $dirty,
    unpushed: $unpushed, unpulled: $unpulled, pr: $pr}'
