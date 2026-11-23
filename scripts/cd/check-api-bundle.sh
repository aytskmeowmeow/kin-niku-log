#!/usr/bin/env bash
# api の本番バンドルに、開発用のもの(/doc・openapi.yaml の中身・localhost:3000)が入っていないかを調べる(D5 の (3)・D21)。
# 対象は実行されるバンドル(bundle/ の下の .map 以外の .js・.mjs・.cjs と、mainModule が指すファイル)だけ。
# ソースマップには元のソースが入り、本番でも必ず失敗するため除く。調べたファイルが 0 個なら失敗にする。
# 判定の文字列は、本番ビルドでは見つからず、NODE_ENV=development のビルドでは見つかるものを実際のバンドルで選んだ。
# ルートのパスは、バンドラの更新で引用符が変わっても見逃さないよう、二重・単一引用符とバッククォートのどれでも拾う。
# 本番にも残る @hono/swagger-ui の import(swagger の文字列)は使わない。
# 使い方: scripts/cd/check-api-bundle.sh [Build Output のディレクトリ(既定: apps/api/.cloudflare/output)]
set -euo pipefail

output_dir="${1:-apps/api/.cloudflare/output}"
worker_dir="${output_dir}/v0/workers/default"
bundle_dir="${worker_dir}/bundle"
config="${worker_dir}/worker.config.json"

# 判定の拡張正規表現と、その説明
q="[\"'\`]"
patterns=('localhost:3000' "${q}/doc${q}" "${q}/openapi\\.yaml${q}" 'openapi: ')
labels=('開発用の CORS オリジン localhost:3000' '/doc のルート' '/openapi.yaml のルート' 'openapi.yaml の中身')

if [ ! -f "${config}" ]; then
  echo "error: ${config} が無い。先に api で cf build する" >&2
  exit 1
fi

main_module=$(jq -r '.manifest.mainModule // empty' "${config}")
if [ -z "${main_module}" ] || [ ! -f "${bundle_dir}/${main_module}" ]; then
  echo "error: メインモジュール(${main_module:-未設定})が ${bundle_dir} に無い" >&2
  exit 1
fi

# 調べるファイル: mainModule(拡張子によらず)と、bundle/ の下の .js・.mjs・.cjs(.map は除く)
files=()
while IFS= read -r -d '' file; do
  files+=("${file}")
done < <(
  {
    printf '%s\0' "${bundle_dir}/${main_module}"
    find "${bundle_dir}" -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.cjs' \) -print0
  } | sort -zu
)

if [ "${#files[@]}" -eq 0 ]; then
  echo "error: ${bundle_dir} に調べるファイルが 1 つも無い" >&2
  exit 1
fi

failed=0
for file in "${files[@]}"; do
  for i in "${!patterns[@]}"; do
    if grep -qE -- "${patterns[$i]}" "${file}"; then
      echo "error: ${file} に ${labels[$i]}(${patterns[$i]})が含まれている" >&2
      failed=1
    fi
  done
done

if [ "${failed}" -ne 0 ]; then
  exit 1
fi
echo "ok: ${#files[@]} 個のファイルを調べた。開発用のものは含まれていない"
