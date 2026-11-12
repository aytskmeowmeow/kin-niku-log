#!/usr/bin/env bash
# PreToolUse hook: kn-implementer から受け入れ要件(acceptance.md)と受け入れテストを隠す。
#
# kn-implementer のエージェント定義の frontmatter から呼ばれ、そのサブエージェントの
# 実行中だけ動く。メインやレビュー用エージェントには効かない。
#
# 判定の規約: 受け入れ要件・受け入れテストは、パスに "acceptance" を含む
# (kn-task-docs の「acceptance.md」節)。
#
# 止めるもの:
#   - Read / Edit / MultiEdit / Write / NotebookEdit: 対象パスに acceptance を含む
#   - Grep / Glob: path / pattern / glob に acceptance を含む。または検索範囲
#     (path、未指定なら cwd)の配下に acceptance を含むパスがある(結果に中身が出るため)
#   - Bash:
#     - コマンドに acceptance を含む
#     - git の差分・履歴の表示(show / diff / log -p 系 / stash show)で、パス指定(--)が無い、
#       または -- の後のパスの配下に受け入れテストがある。受け入れテストは実装前に
#       コミットされるので、履歴からも読める
#     - 再帰的な検索・一覧(grep -r / rg / find / tree / git grep / ls -R)の範囲の配下に
#       受け入れテストがある
#
# 限界: 変数展開・glob 展開・スクリプト経由の読み込みはコマンド文字列からは判定できない。
# 「普通にやると読めない」水準が目標で、エージェント定義の禁止事項と二重にしている。
#
# ブロックは exit 2(権限ルールで上書きされない)。stderr が理由としてエージェントに渡る。

set -f # コマンドを単語に分けるとき、glob を展開させない

input=$(cat)

if ! command -v jq >/dev/null 2>&1; then
  echo "acceptance-guard: jq が見つからないため判定できません。ユーザーに jq の導入を依頼してください。" >&2
  exit 2
fi

tool=$(printf '%s' "$input" | jq -r '.tool_name // ""')
cwd=$(printf '%s' "$input" | jq -r '.cwd // ""')
[ -n "$cwd" ] || cwd=${CLAUDE_PROJECT_DIR:-$PWD}

deny() {
  cat >&2 <<EOF
acceptance-guard: $1

acceptance.md と受け入れテスト(パスに "acceptance" を含むもの)は、実装エージェントには非公開です。
- 仕様は design.md を読んでください。仕様に疑問があれば、仕様の言葉で疑問としてメインに返してください
- 検索は apps/*/src や packages/*/src などのソースのディレクトリに絞ってください
- git の差分・履歴は "git diff -- apps/api/src" のように、ソースのパスを指定してください
EOF
  exit 2
}

mentions_acceptance() {
  printf '%s' "$1" | grep -qi 'acceptance'
}

# 相対パスを cwd 基準の絶対パスにする
resolve() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$cwd" "$1" ;;
  esac
}

# 引数のディレクトリ配下に acceptance を含むパスがあれば 0 を返す
subtree_has_acceptance() {
  local dir
  dir=$(resolve "$1")
  [ -d "$dir" ] || return 1
  local hit
  # .claude/hooks はこの hook 自身(acceptance-guard.sh)を含むため除く
  hit=$(find "$dir" \( -name node_modules -o -name .git -o -name .turbo -o -name dist -o -name .cloudflare -o -path '*/.claude/hooks' \) -prune \
    -o -ipath '*acceptance*' -print 2>/dev/null | head -n 1)
  [ -n "$hit" ]
}

strip_quotes() {
  local w=$1
  w=${w#\"}; w=${w%\"}; w=${w#\'}; w=${w%\'}
  printf '%s' "$w"
}

# 単語列の中のディレクトリを調べる。ディレクトリが 1 つも無ければ cwd を調べる
check_search_scope() {
  local found=0 w
  for w in "$@"; do
    case "$w" in -*) continue ;; esac
    w=$(strip_quotes "$w")
    if [ -d "$(resolve "$w")" ]; then
      found=1
      subtree_has_acceptance "$w" && deny "検索範囲($w)に受け入れテストが含まれます。範囲をソースのディレクトリに絞ってください"
    fi
  done
  if [ "$found" -eq 0 ]; then
    subtree_has_acceptance "$cwd" && deny "範囲を指定しない再帰検索は、受け入れテストを含みます。範囲をソースのディレクトリに絞ってください"
  fi
  return 0
}

# Bash の 1 セグメント(パイプ・; ・&& で区切った単位)を判定する
check_segment() {
  # shellcheck disable=SC2086
  set -- $1
  [ $# -gt 0 ] || return 0

  # 先頭の環境変数代入(FOO=bar cmd)を飛ばす
  while [ $# -gt 0 ]; do
    case "$1" in
      *=*) shift ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || return 0

  local cmd=$1
  shift
  case "$cmd" in
    git)
      # グローバルオプション(-C <path> / -c <k=v> / --git-dir=... / --no-pager など)を飛ばす
      while [ $# -gt 0 ]; do
        case "$1" in
          -C|-c|--git-dir|--work-tree|--namespace) shift 2 ;;
          -*) shift ;;
          *) break ;;
        esac
      done
      [ $# -gt 0 ] || return 0
      local sub=$1
      shift
      local shows_content=0
      case "$sub" in
        show|diff|whatchanged) shows_content=1 ;;
        log)
          local a
          for a in "$@"; do
            case "$a" in
              -p|-u|--patch|--patch-*|-p*|--full-diff|--stat*) shows_content=1 ;;
            esac
          done
          ;;
        stash)
          [ "${1:-}" = "show" ] && shows_content=1
          ;;
        grep)
          check_search_scope "$@"
          return 0
          ;;
      esac
      if [ "$shows_content" -eq 1 ]; then
        local seen_dd=0 paths=0 a
        for a in "$@"; do
          if [ "$seen_dd" -eq 1 ]; then
            paths=1
            a=$(strip_quotes "$a")
            mentions_acceptance "$a" && deny "受け入れテストの差分・履歴は表示できません"
            subtree_has_acceptance "$a" && deny "指定したパス($a)の配下に受け入れテストが含まれます。ソースのパスを指定してください"
          elif [ "$a" = "--" ]; then
            seen_dd=1
          fi
        done
        [ "$paths" -eq 1 ] || deny "git の差分・履歴(show / diff / log -p など)はパスを指定してください(例: git diff -- apps/api/src)"
      fi
      ;;
    rg|find|tree)
      check_search_scope "$@"
      ;;
    grep|egrep|fgrep)
      local a recursive=0
      for a in "$@"; do
        case "$a" in
          --recursive|--dereference-recursive) recursive=1 ;;
          --*) ;;
          -*[rR]*) recursive=1 ;;
        esac
      done
      [ "$recursive" -eq 1 ] && check_search_scope "$@"
      ;;
    ls)
      local a
      for a in "$@"; do
        case "$a" in
          --recursive) check_search_scope "$@"; return 0 ;;
          --*) ;;
          -*R*) check_search_scope "$@"; return 0 ;;
        esac
      done
      ;;
  esac
  return 0
}

case "$tool" in
  Read|Edit|MultiEdit|Write)
    path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""')
    mentions_acceptance "$path" && deny "受け入れ要件・受け入れテストのファイルは扱えません($path)"
    ;;
  NotebookEdit)
    path=$(printf '%s' "$input" | jq -r '.tool_input.notebook_path // ""')
    mentions_acceptance "$path" && deny "受け入れ要件・受け入れテストのファイルは扱えません($path)"
    ;;
  Grep|Glob)
    path=$(printf '%s' "$input" | jq -r '.tool_input.path // ""')
    pattern=$(printf '%s' "$input" | jq -r '.tool_input.pattern // ""')
    glob=$(printf '%s' "$input" | jq -r '.tool_input.glob // ""')
    if mentions_acceptance "$path$pattern$glob"; then
      deny "受け入れ要件・受け入れテストは検索できません"
    fi
    [ -n "$path" ] || path=$cwd
    [ -f "$(resolve "$path")" ] && exit 0
    subtree_has_acceptance "$path" && deny "検索範囲($path)に受け入れテストが含まれます。範囲をソースのディレクトリに絞ってください"
    ;;
  Bash)
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')
    mentions_acceptance "$cmd" && deny "コマンドが受け入れ要件・受け入れテストに触れています"
    # パイプ・; ・&& ・|| ・改行でセグメントに分けて、それぞれを判定する
    # (macOS の sed は置換後の \n を改行にしないので、bash の置換で分ける)
    nl=$'\n'
    segments=${cmd//&&/$nl}
    segments=${segments//||/$nl}
    segments=${segments//|/$nl}
    segments=${segments//;/$nl}
    segments=${segments//&/$nl}
    while IFS= read -r seg; do
      check_segment "$seg"
    done <<EOF
$segments
EOF
    ;;
esac

exit 0
