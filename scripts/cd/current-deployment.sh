#!/usr/bin/env bash
# Worker の今の先頭のデプロイ(ID と versions)を、1 行の JSON で標準出力に出す(#32 D2・D3)。
# 使い方: scripts/cd/current-deployment.sh <Worker 名>
# 出力: {"id":"...","versions":[{"version_id":"...","percentage":100}]}(versions は version_id 順)
# 一覧の JSON には author_email などが含まれるので、ID と versions 以外は出さない。
# 取れなかったとき(cf の失敗・JSON でない・先頭が無い・id か versions が空)は終了コード 1。
# 環境変数(ローカルの検証用): CF(既定 node_modules/.bin/cf。apps/<app> で動かす前提)
set -euo pipefail

worker="${1:-}"
cf="${CF:-node_modules/.bin/cf}"

if [ -z "${worker}" ]; then
  echo "usage: $0 <Worker 名>" >&2
  exit 2
fi

if ! list=$("${cf}" workers deployments list --worker "${worker}"); then
  echo "::error::${worker} のデプロイの一覧を取得できなかった" >&2
  exit 1
fi

# jq の失敗メッセージに一覧の値が入りうるので、標準エラーは捨てる
if ! result=$(
  printf '%s' "${list}" | jq -c '
    .deployments[0] as $d
    | if ($d.id // "") == "" or (($d.versions // []) | length) == 0 then
        empty
      else
        {id: $d.id, versions: ($d.versions | map({version_id, percentage}) | sort_by(.version_id))}
      end
  ' 2>/dev/null
); then
  echo "::error::${worker} のデプロイの一覧を読めなかった(JSON でない、または形が違う)" >&2
  exit 1
fi

if [ -z "${result}" ]; then
  echo "::error::${worker} の先頭のデプロイの ID か versions を取り出せなかった" >&2
  exit 1
fi

printf '%s\n' "${result}"
