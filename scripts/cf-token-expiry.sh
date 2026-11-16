#!/usr/bin/env bash
# Cloudflare API トークン(CD 用)の有効期限を運用文書から読み、状態を 1 行で出す。
#
# 呼び出し元: .claude/hooks/cf-token-expiry-reminder.sh(SessionStart hook)と
# .github/workflows/cf-token-expiry-reminder.yml(定期実行)。判定はここだけに置く。
# 経緯と判断は docs/issues/23-cf-token-scope/ を参照。
#
# 使い方: scripts/cf-token-expiry.sh [運用文書のパス]
#   運用文書のパスを省くと、このスクリプトの場所から求めたリポジトリのルートの
#   docs/operations/cloudflare-api-token.md を読む(カレントディレクトリに依存しない)。
#   環境変数 CF_TOKEN_EXPIRY_TODAY(YYYY-MM-DD)で今日の日付を上書きできる(テスト用)。
#
# 出力(標準出力に 1 行):
#   not-issued                  期限日の行が「未発行」
#   ok <期限日> <残り日数>       残り 15 日以上
#   due <期限日> <残り日数>      残り 1〜14 日
#   expired <期限日> <経過日数>  残り 0 日以下(終了日の UTC 0 時に失効するとみなす)
#   invalid <理由>               期限日を読めない(運用文書の問題)
#   invalid-today <値>           今日の日付の上書き(CF_TOKEN_EXPIRY_TODAY)が不正(呼び出し側の問題)
# 終了コードは常に 0。呼び出し側が状態で分岐する。
#
# 日付はすべて UTC で扱う(Cloudflare のトークンの終了日が UTC 0 時単位のため)。

set -u

readonly THRESHOLD_DAYS=14
readonly PREFIX='- 有効期限: '

# CDPATH が設定されていると cd が移動先を標準出力に出すので、空にしてから移動する
script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(dirname "$script_dir")
doc=${1:-"$repo_root/docs/operations/cloudflare-api-token.md"}

# YYYY-MM-DD を、その日の UTC 0 時の UNIX 時刻に直す。実在しない日付なら失敗する。
# macOS(BSD の date)と Linux(GNU の date)の両方で動かす。
to_epoch() {
  local d=$1 e back
  [[ $d =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
  if e=$(TZ=UTC date -j -f '%Y-%m-%d %H:%M:%S' "$d 00:00:00" +%s 2>/dev/null); then
    back=$(TZ=UTC date -j -r "$e" +%Y-%m-%d) || return 1
  elif e=$(TZ=UTC date -d "$d 00:00:00" +%s 2>/dev/null); then
    back=$(TZ=UTC date -d "@$e" +%Y-%m-%d) || return 1
  else
    return 1
  fi
  # BSD の date は 2027-02-30 を 3 月に繰り越して受け付けるので、往復して一致するかで実在を確かめる
  [ "$back" = "$d" ] || return 1
  printf '%s\n' "$e"
}

# 今日の日付は運用文書より先に確かめる(打ち間違いが not-issued や invalid に隠れないように)
today=${CF_TOKEN_EXPIRY_TODAY:-}
[ -n "$today" ] || today=$(date -u +%Y-%m-%d)
if ! today_epoch=$(to_epoch "$today"); then
  echo "invalid-today $today"
  exit 0
fi

if [ ! -f "$doc" ]; then
  echo "invalid 運用文書が見つからない($doc)"
  exit 0
fi

count=0
value=
while IFS= read -r line || [ -n "$line" ]; do
  line=${line%$'\r'}
  case $line in
    "$PREFIX"*)
      count=$((count + 1))
      value=${line#"$PREFIX"}
      ;;
  esac
done <"$doc"

if [ "$count" -eq 0 ]; then
  echo "invalid 期限日の行が無い"
  exit 0
fi
if [ "$count" -gt 1 ]; then
  echo "invalid 期限日の行が複数ある(${count} 行)"
  exit 0
fi
if [ "$value" = "未発行" ]; then
  echo "not-issued"
  exit 0
fi
if ! [[ $value =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "invalid 期限日の形式が違う($value)"
  exit 0
fi
if ! expiry_epoch=$(to_epoch "$value"); then
  echo "invalid 期限日が実在しない日付($value)"
  exit 0
fi

remaining=$(((expiry_epoch - today_epoch) / 86400))
if [ "$remaining" -le 0 ]; then
  echo "expired $value $((-remaining))"
elif [ "$remaining" -le "$THRESHOLD_DAYS" ]; then
  echo "due $value $remaining"
else
  echo "ok $value $remaining"
fi
exit 0
