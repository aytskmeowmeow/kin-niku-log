#!/usr/bin/env bash
# SessionStart hook: Cloudflare API トークン(CD 用)の期限が近い・切れた・読めないとき、
# Claude にリマインドを渡す。標準出力は Claude の文脈に入る(SessionStart hook の仕様)。
#
# 登録: .claude/settings.json(matcher なし。startup / resume / clear / compact のすべてで動く)
# 判定: scripts/cf-token-expiry.sh(定期実行ワークフローと共用)
# 経緯と判断: docs/issues/23-cf-token-scope/(design.md の D9)
#
# どんな場合も終了コード 0 で終える(セッションの開始を妨げない)。
# スクリプトが無い・失敗したときも黙らずに知らせる(リマインドが止まったことに気づけるように)。

set -u

readonly DOC_REL=docs/operations/cloudflare-api-token.md

remind() {
  cat <<EOF
[リマインド] Cloudflare API トークン(CD 用): $1
最初の返答の冒頭で、このことをユーザーに伝えてください。手順は ${DOC_REL} にあります。
EOF
  exit 0
}

project_dir=${CLAUDE_PROJECT_DIR:-}
script="$project_dir/scripts/cf-token-expiry.sh"
if [ -z "$project_dir" ] || [ ! -f "$script" ]; then
  remind "期限チェックのスクリプト(scripts/cf-token-expiry.sh)が見つからず、期限を確かめられませんでした。"
fi

status=$(bash "$script" 2>/dev/null) || status=
[ -n "$status" ] || remind "期限チェックのスクリプトが失敗し、期限を確かめられませんでした。"

read -r state expiry days _ <<<"$status"
case $state in
  ok | not-issued) exit 0 ;;
  due) remind "あと ${days} 日で期限(${expiry})が切れます。入れ替えてください。" ;;
  expired) remind "期限(${expiry})を過ぎています。CD のデプロイは失敗します。入れ替えてください。" ;;
  invalid) remind "運用文書の期限日を読めません(${status#invalid })。リマインドが働いていない状態です。" ;;
  invalid-today) remind "今日の日付の上書き(環境変数 CF_TOKEN_EXPIRY_TODAY=${expiry})が YYYY-MM-DD の実在する日付でないため、期限を判定できませんでした。" ;;
  *) remind "期限チェックの結果を解釈できませんでした(${status})。" ;;
esac
