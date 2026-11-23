#!/usr/bin/env bash
# デプロイ後の確認(D6・D14)。
# 使い方: scripts/cd/smoke.sh <api|web> <URL(末尾のスラッシュなし)>
# 確認ごとに、通るまで最大 SMOKE_ATTEMPTS 回、SMOKE_INTERVAL 秒間隔で繰り返す。最後まで通らなければ終了コード 1。
# 環境変数(ローカルの検証用。ワークフローでは上書きしない):
#   SMOKE_ATTEMPTS(既定 10)/ SMOKE_INTERVAL(既定 6)/ SMOKE_FOREIGN_ORIGIN(既定 https://example.com)
set -euo pipefail

target="${1:-}"
base_url="${2:-}"
attempts="${SMOKE_ATTEMPTS:-10}"
interval="${SMOKE_INTERVAL:-6}"
foreign_origin="${SMOKE_FOREIGN_ORIGIN:-https://example.com}"

if [ -z "${base_url}" ] || { [ "${target}" != api ] && [ "${target}" != web ]; }; then
  echo "usage: $0 <api|web> <URL>" >&2
  exit 2
fi
base_url="${base_url%/}"

# 応答コードを返す。接続の失敗は 000 になる
status_of() {
  curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "$@" || true
}

# 1 回の試行。通れば 0、通らなければ 1(理由を標準出力に 1 行出す)
check_status() {
  local path="$1" expected="$2" actual
  actual=$(status_of "${base_url}${path}")
  if [ "${actual}" = "${expected}" ]; then
    return 0
  fi
  echo "GET ${path}: 期待 ${expected}、実際 ${actual}"
  return 1
}

# 許可オリジン以外の Origin を付けた /health に、Access-Control-Allow-Origin が付かないこと
check_no_cors_header() {
  local headers
  headers=$(curl -s -o /dev/null -D - --connect-timeout 5 --max-time 10 \
    -H "Origin: ${foreign_origin}" "${base_url}/health" || true)
  if [ -z "${headers}" ]; then
    echo "GET /health(Origin: ${foreign_origin}): 応答なし(接続の失敗)"
    return 1
  fi
  if printf '%s' "${headers}" | grep -iq '^access-control-allow-origin:'; then
    echo "GET /health(Origin: ${foreign_origin}): Access-Control-Allow-Origin が付いている(期待: 付かない)"
    return 1
  fi
  return 0
}

# 通るまで繰り返す。$1 は説明、残りは実行する関数と引数
run_with_retry() {
  local label="$1" n reason=""
  shift
  for ((n = 1; n <= attempts; n++)); do
    if reason=$("$@"); then
      echo "ok: ${label}"
      return 0
    fi
    echo "retry ${n}/${attempts}: ${label}: ${reason}" >&2
    if [ "${n}" -lt "${attempts}" ]; then
      sleep "${interval}"
    fi
  done
  echo "error: ${label}: ${attempts} 回試しても通らない(最後の結果: ${reason})" >&2
  return 1
}

failed=0
case "${target}" in
  api)
    run_with_retry "api GET /health が 200" check_status /health 200 || failed=1
    run_with_retry "api GET /doc が 404" check_status /doc 404 || failed=1
    run_with_retry "api GET /openapi.yaml が 404" check_status /openapi.yaml 404 || failed=1
    run_with_retry "api の許可オリジン以外に CORS ヘッダーが付かない" check_no_cors_header || failed=1
    ;;
  web)
    run_with_retry "web GET / が 200" check_status / 200 || failed=1
    ;;
esac
exit "${failed}"
