# shellcheck shell=bash
# 偽の gh のうち、GitHub Project（gh project と REST の projectsV2）と所有者（REST の users/<login>）を受け持つ部分。
# 各テストの偽の gh の先頭で `. "$FAKE_GH_PROJECT"; fake_gh_project "$@"` のように読み込んで呼ぶ。
# 当てはまる呼び出しなら応答を出して終了し、当てはまらなければ何もせずに戻る。
#
# 呼び出しごとに操作名を決め、「<操作名> <引数の JSON>」を $CALLS に記録して、$FIX/<操作名>.json を返す
# （同じ操作の n 回目には <操作名>.<n>.json があればそれを返す。無ければ {}）。
# 引数の JSON は、--foo bar を {"foo": "bar"} に、それ以外を {"_": [...]} にまとめたもの（REST はパスを {"path": ...}）。
#   gh project view                  ProjectView
#   gh project list                  Projects
#   gh project create                CreateProject
#   gh project link                  LinkRepo
#   gh project field-create          CreateNumberField
#   gh project item-add              AddItem
#   gh project item-edit             SetField
#   gh api users/<login>             Owner
#   gh api .../projectsV2/N/fields   ProjectFields
# FAKE_FAIL に指定した操作名は、FAKE_FAIL_MSG（既定: gh: failed）を出して失敗する。

fake_gh_project() {
  local op="" path="" args n
  case "$1 ${2:-}" in
    "project view") op=ProjectView ;;
    "project list") op=Projects ;;
    "project create") op=CreateProject ;;
    "project link") op=LinkRepo ;;
    "project field-create") op=CreateNumberField ;;
    "project item-add") op=AddItem ;;
    "project item-edit") op=SetField ;;
    "api "*)
      shift
      [ "$1" = --paginate ] && shift
      path="$1"
      case "$path" in
        users/* | orgs/*)
          case "$path" in
            */projectsV2/*/fields*) op=ProjectFields ;;
            users/*/*) ;;
            users/*) op=Owner ;;
          esac
          ;;
      esac
      ;;
  esac
  [ -n "$op" ] || return 0
  if [ -n "$path" ]; then
    args="$(jq -nc --arg p "$path" '{path: $p}')"
  else
    shift 2
    args='{"_": []}'
    while [ $# -gt 0 ]; do
      case "$1" in
        --*)
          args="$(jq -c --arg k "${1#--}" --arg v "${2:-}" '.[$k] = $v' <<<"$args")"
          shift 2
          ;;
        *)
          args="$(jq -c --arg v "$1" '._ += [$v]' <<<"$args")"
          shift
          ;;
      esac
    done
  fi
  echo "$op $args" >>"$CALLS"
  if [ "${FAKE_FAIL:-}" = "$op" ]; then
    echo "${FAKE_FAIL_MSG:-gh: failed}" >&2
    exit 1
  fi
  n="$(grep -c "^$op " "$CALLS")"
  if [ -f "$FIX/$op.$n.json" ]; then cat "$FIX/$op.$n.json"
  elif [ -f "$FIX/$op.json" ]; then cat "$FIX/$op.json"
  else echo '{}'; fi
  exit 0
}
