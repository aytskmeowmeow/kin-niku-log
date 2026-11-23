#!/usr/bin/env bash
# デプロイ後の確認が失敗した Worker を、デプロイ前のバージョンに戻す(#32 D1〜D5・D15・D18)。
# 使い方: scripts/cd/rollback.sh <api|web> <Worker 名> <戻し先の JSON(current-deployment.sh の出力)> <確認の URL>
# 手順: 今の先頭を取る → 戻し先と同じなら何もしない → deployments create で戻す(強制しない)
#       → 一覧を読み直して確かめる → 戻した後の確認(smoke.sh)
# 結果は GITHUB_OUTPUT に status・worker・version を 1 回だけ書く(終了時の trap)。
#   status: rolled_back(戻して確認も通った)/ unhealthy(戻したが確認が通らない)
#           / failed(戻せなかった・戻せたか分からない)/ not_needed(新しいデプロイが作られていなかった)
#   version: 戻した版の version_id を , でつないだもの(戻していなければ空)
# 終了コードは、引数の誤り(2)と予期せず止まった場合を除き 0(結果は出力で伝える)。
# 一覧の JSON には author_email などが含まれるので、ID と versions 以外は出さない。
# 環境変数(ローカルの検証用): CF(既定 node_modules/.bin/cf。apps/<app> で動かす前提)
set -euo pipefail

target="${1:-}"
worker="${2:-}"
prior="${3:-}"
url="${4:-}"
cf="${CF:-node_modules/.bin/cf}"
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

status=failed
version=""
reported=0

# 結果の注記と実行の概要を出す
report() {
  local kind text
  case "${status}" in
    rolled_back)
      kind=error
      text="${worker} を戻した(戻した版: ${version})。戻した後の確認は通った"
      ;;
    unhealthy)
      kind=error
      text="${worker} を戻したが、戻した後の確認が通らない(戻した版: ${version})"
      ;;
    not_needed)
      kind=warning
      text="${worker} は新しいデプロイが作られていないので、戻すものが無かった"
      ;;
    *)
      kind=error
      text="${worker} を戻せなかった(戻せたか分からない場合を含む)。手でのロールバックが必要(docs/operations/deploy.md)"
      ;;
  esac
  echo "::${kind}::${text}"
  {
    echo "### 自動ロールバック"
    echo
    echo "- Worker: ${worker}"
    echo "- 結果: ${status}"
    echo "- ${text}"
  } >>"${GITHUB_STEP_SUMMARY:-/dev/null}" || true
}

# 終了時に、まだ結果を出していなければ failed として出し、出力を 1 回だけ書く
on_exit() {
  local code=$?
  if [ "${reported}" -eq 0 ]; then
    status=failed
    version=""
    report
  fi
  {
    printf 'status=%s\n' "${status}"
    printf 'worker=%s\n' "${worker}"
    printf 'version=%s\n' "${version}"
  } >>"${GITHUB_OUTPUT:-/dev/null}"
  exit "${code}"
}
trap on_exit EXIT

# 結果を決めて注記・概要を出し、正常終了する
finish() {
  status="$1"
  version="${2:-}"
  reported=1
  report
  exit 0
}

if { [ "${target}" != api ] && [ "${target}" != web ]; } || [ -z "${worker}" ] || [ -z "${prior}" ] || [ -z "${url}" ]; then
  echo "usage: $0 <api|web> <Worker 名> <戻し先の JSON> <確認の URL>" >&2
  exit 2
fi

prior_id=$(printf '%s' "${prior}" | jq -r '.id')
prior_versions=$(printf '%s' "${prior}" | jq -c '.versions | map({version_id, percentage}) | sort_by(.version_id)')
prior_version_ids=$(printf '%s' "${prior_versions}" | jq -r 'map(.version_id) | join(",")')
echo "戻し先: id=${prior_id} versions=${prior_versions}"

# 1. 今の先頭を取る
if ! now=$(bash "${here}/current-deployment.sh" "${worker}"); then
  echo "今の先頭のデプロイを取れず、新しいデプロイの有無を決められない"
  finish failed
fi
now_id=$(printf '%s' "${now}" | jq -r '.id')
echo "今の先頭: id=${now_id}"

# 2. 戻し先と同じなら、新しいデプロイは作られていない
if [ "${now_id}" = "${prior_id}" ]; then
  echo "先頭が戻し先と同じ: 戻すものが無い"
  finish not_needed
fi

# 3. 戻す(強制しない。標準出力は捨て、標準エラーは流す)
echo "戻す: ${worker} を ${prior_versions} にする"
if ! "${cf}" workers deployments create --worker "${worker}" --strategy percentage --versions "${prior_versions}" >/dev/null; then
  echo "cf workers deployments create が失敗した"
  finish failed
fi

# 4. 一覧を読み直して確かめる
if ! after=$(bash "${here}/current-deployment.sh" "${worker}"); then
  echo "戻した後の一覧を取れず、戻せたか分からない"
  finish failed
fi
after_id=$(printf '%s' "${after}" | jq -r '.id')
after_versions=$(printf '%s' "${after}" | jq -c '.versions')
echo "読み直した先頭: id=${after_id} versions=${after_versions}"
if [ "${after_id}" = "${now_id}" ] || [ "${after_versions}" != "${prior_versions}" ]; then
  echo "判定: 戻せていない(先頭が増えていない、または versions が戻し先と違う)"
  finish failed
fi
echo "判定: 戻せた(先頭が新しく増え、versions が戻し先と同じ)"

# 5. 戻した後の確認(入力の失敗扱いは効かない。D15)
if bash "${here}/smoke.sh" "${target}" "${url}"; then
  finish rolled_back "${prior_version_ids}"
fi
finish unhealthy "${prior_version_ids}"
