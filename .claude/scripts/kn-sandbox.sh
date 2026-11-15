#!/usr/bin/env bash
# kn-implementer を Docker Sandboxes の VM で動かす(docs/agent-workflow/design.md の D42〜D48)。
#
# VM には、受け入れ要件(パスに "acceptance" を含むファイル。.claude/hooks/ の下は除かない)を
# 除いた作業場所だけをマウントする。作業場所は今の作業ツリーから書き出し、元のリポジトリの
# 履歴は渡さない。
#
# 差分を取るための git(スナップショット)はマウントの外の <タスク>/git に置き、ホストの git が
# VM の書き換えられる設定に従わないようにする。作業場所の中の .git は、kn-implementer が
# VM の中で差分を見るためだけのもので、VM の中で作り、ホスト側では使わない。
# ホストが作業場所に書き込む・読む間は VM を止めておく(VM の中のプロセスと競合させない)。
#
# 使い方は usage を参照。メインが kn-dev-workflow の「4. 実装」で使う。
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
使い方: kn-sandbox.sh <サブコマンド> <タスク> [引数]

  create   <タスク>                       VM kn-<タスク> を作り、package.json の版の bun を入れ、GitHub への通信を止める
  recreate <タスク>                       壊れた VM だけを消して create し直す(置き場所と記録は残す)
  prepare  <タスク> [--force]             今の作業ツリーから受け入れ要件を除いて作業場所に書き出す。
                                          取り込んでいない kn-implementer の変更があれば止まる(--force で捨てる)
  run      <タスク> <プロンプトのファイル> [--continue]
                                          VM の中で kn-implementer を動かし、報告を標準出力に出す。
                                          --continue は同じ VM の直前の会話を続ける
  collect  <タスク>                       VM での変更を、元のリポジトリの作業ツリーに取り込む
  rm       <タスク>                       VM と置き場所を消す(PR のマージ後に使う)

<タスク> は英小文字・数字・ハイフン(例: 23-meal-log)。
置き場所は ~/.cache/kn-sandbox/<タスク>/ で、作業場所は ws/、委譲プロンプトは prompt.md に書く。
EOF
  exit 2
}

die() {
  echo "kn-sandbox: $*" >&2
  exit 1
}

[ $# -ge 2 ] || usage
cmd="$1"
task="$2"
shift 2

[[ "$task" =~ ^[a-z0-9][a-z0-9-]{0,40}[a-z0-9]$ ]] || die "タスク名は英小文字・数字・ハイフンで 2〜42 文字にしてください: $task"

command -v sbx >/dev/null 2>&1 || die "sbx が見つかりません。Docker Sandboxes の導入をユーザーに依頼してください"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(git -C "$script_dir" rev-parse --show-toplevel)"
base_dir="${KN_SANDBOX_HOME:-$HOME/.cache/kn-sandbox}/$task"
ws="$base_dir/ws"
snap="$base_dir/git"
vm="kn-$task"

# VM の中で読ませる規約スキルの一覧(D47 (a)・D49)。スキルを増やすときは一覧のファイルだけを直す
skills_list="$script_dir/kn-sandbox-skills.txt"

# 一覧のファイルからスキル名を読む(空行と # 以降は無視)
read_rule_skills() {
  [ -f "$skills_list" ] || die "規約スキルの一覧がありません: $skills_list"
  rule_skills=()
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | tr -d '[:space:]')"
    [ -z "$line" ] && continue
    [[ "$line" =~ ^[A-Za-z0-9._-]+$ ]] || die "規約スキルの一覧に、スキル名として使えない行があります: $line"
    rule_skills+=("$line")
  done <"$skills_list"
  [ ${#rule_skills[@]} -gt 0 ] || die "規約スキルの一覧が空です: $skills_list"
}

# VM から止める通信(D47 (f))
github_hosts='github.com,*.github.com,*.githubusercontent.com'

vm_exists() {
  sbx --no-input inspect "$vm" >/dev/null 2>&1
}

vm_stop() {
  if vm_exists; then
    sbx --no-input stop "$vm" >/dev/null 2>&1 || true
  fi
}

# スナップショット用の git。設定はホスト側の $snap にしか無く、VM からは書き換えられない。
# フック・fsmonitor・テンプレートは使わない。作業場所の .gitattributes は $snap/info/attributes で打ち消す
snapgit() {
  git --git-dir="$snap" --work-tree="$ws" \
    -c core.hooksPath=/dev/null -c core.fsmonitor=false -c core.quotePath=false "$@"
}

is_tree_id() {
  [[ "$1" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]
}

# パスが collect で取り込めないものなら 0 を返す(D47 (d)・D48 (e))
is_forbidden_path() {
  # ホスト(macOS)のファイルシステムは大文字小文字を区別しないので、すべて小文字にしてから比べる
  local lower name
  lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in *acceptance*) return 0 ;; esac
  case "/$lower" in */.claude/*) return 0 ;; esac
  name="${lower##*/}"
  case "$name" in claude.md | claude.local.md) return 0 ;; esac
  [ "$lower" = ".mcp.json" ] && return 0
  case "$lower" in
    docs/*) case "$name" in design.md | acceptance.md | impl.md) return 0 ;; esac ;;
  esac
  return 1
}

# 今の作業ツリーの状態を、元のリポジトリの index を変えずに tree オブジェクトにして出力する。
# 追跡しているファイル(add 済みの新しいファイルを含む)の変更・削除と、gitignore の対象でない
# 新しいファイルを含む。新しいファイルのうちパスのどこかの要素が "." で始まるものは、
# collect が取り込んだものを除いて含めない(D47 (c)・D48 (c))。
worktree_tree() {
  local tmp idx tree collected="$base_dir/collected"
  tmp="$(mktemp -d)"
  idx="$tmp/index"
  # add 済みで未コミットの新しいファイルも含めるため、本物の index の写しから始める
  if ! cp "$(git -C "$repo" rev-parse --absolute-git-dir)/index" "$idx" 2>/dev/null; then
    GIT_INDEX_FILE="$idx" git -C "$repo" read-tree HEAD || { rm -rf "$tmp"; return 1; }
  fi
  GIT_INDEX_FILE="$idx" git -C "$repo" add -u -- . || { rm -rf "$tmp"; return 1; }
  GIT_INDEX_FILE="$idx" git -C "$repo" ls-files --others --exclude-standard -z >"$tmp/others" ||
    { rm -rf "$tmp"; return 1; }
  while IFS= read -r -d '' f; do
    case "/$f" in
      */.*)
        if [ -f "$collected" ] && grep -Fxq -- "$f" "$collected"; then
          printf '%s\0' "$f"
        else
          echo "kn-sandbox: パスに \".\" で始まる要素がある新しいファイルは書き出しません: $f" >&2
        fi
        ;;
      *) printf '%s\0' "$f" ;;
    esac
  done <"$tmp/others" >"$tmp/add"
  GIT_INDEX_FILE="$idx" git -C "$repo" update-index --add -z --stdin <"$tmp/add" || { rm -rf "$tmp"; return 1; }
  tree="$(GIT_INDEX_FILE="$idx" git -C "$repo" write-tree)" || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  is_tree_id "$tree" || return 1
  printf '%s\n' "$tree"
}

# 作業場所の今の状態を index に載せ、その tree を出力する(スナップショット用の git で)
ws_tree() {
  snapgit add -A >/dev/null && snapgit write-tree
}

base_tree() {
  snapgit rev-parse "$(cat "$base_dir/base")^{tree}"
}

# 作業場所の index の状態を新しい base にする
advance_base() {
  local commit
  commit="$(snapgit -c user.name=kn-sandbox -c user.email=kn-sandbox@localhost -c commit.gpgsign=false \
    commit -q --no-verify --allow-empty -m "kn-sandbox collected" && snapgit rev-parse HEAD)"
  printf '%s\n' "$commit" >"$base_dir/base"
}

cmd_create() {
  vm_exists && die "VM $vm はもうあります。壊れたなら recreate、使い終わったなら rm してください"
  mkdir -p "$ws"
  rm -f "$base_dir/created"
  local pm version
  pm="$(jq -r '.packageManager // empty' "$repo/package.json")"
  [[ "$pm" =~ ^bun@([0-9][0-9A-Za-z.+-]*)$ ]] || die "package.json の packageManager から bun の版を読めません: ${pm:-(なし)}"
  version="${BASH_REMATCH[1]}"
  sbx --no-input create --name "$vm" claude "$ws" >&2
  # ここから先で失敗したら、GitHub を止めていない VM を残さない
  trap 'echo "kn-sandbox: create の途中で失敗したので VM を消します" >&2; sbx --no-input rm --force "$vm" >/dev/null 2>&1 || true' ERR
  sbx --no-input exec "$vm" curl -fsSL https://bun.sh/install -o /tmp/bun-install.sh
  sbx --no-input exec -e BUN_INSTALL=/home/agent/.local "$vm" bash /tmp/bun-install.sh "bun-v$version" >&2
  # bun を入れた後で GitHub を止める(配布元が GitHub のため)
  sbx --no-input policy deny network "$github_hosts" --sandbox "$vm" >&2
  trap - ERR
  date -u +%Y-%m-%dT%H:%M:%SZ >"$base_dir/created"
  echo "kn-sandbox: VM $vm を作りました(bun $(sbx --no-input exec "$vm" bun --version)、GitHub への通信は停止)" >&2
}

cmd_recreate() {
  if vm_exists; then
    sbx --no-input rm --force "$vm" >&2
  fi
  cmd_create
  echo "kn-sandbox: 置き場所は残しました。VM の中の会話は消えたので、次の run は --continue を付けずに引き継いでください" >&2
}

cmd_prepare() {
  local force=0
  if [ $# -ge 1 ]; then
    [ "$1" = "--force" ] || usage
    force=1
  fi
  mkdir -p "$ws"
  vm_stop

  # 取り込んでいない kn-implementer の変更を黙って消さない
  if [ -f "$base_dir/base" ] && [ "$force" -eq 0 ]; then
    local now
    now="$(ws_tree)" || die "作業場所の状態を読めません。prepare --force でやり直してください"
    if [ "$now" != "$(base_tree)" ]; then
      die "作業場所に、まだ取り込んでいない kn-implementer の変更があります。collect してください(捨てるなら --force)"
    fi
  fi

  local s
  read_rule_skills
  for s in "${rule_skills[@]}"; do
    [ -f "$HOME/.claude/skills/$s/SKILL.md" ] ||
      die "規約スキルが見つかりません: ~/.claude/skills/${s}。kn-implementer が規約なしで実装しないよう止めます"
  done

  local tree
  tree="$(worktree_tree)" || die "元のリポジトリの作業ツリーを読めません"

  # 途中で失敗したら、次の prepare が「取り込んでいない変更」と誤って止まらないよう、先に base を消す
  rm -f "$base_dir/base"
  # VM がマウントしているディレクトリ自体は消さず、中身だけを入れ替える
  find "$ws" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  # 受け入れ要件を除いて書き出す。.claude/hooks/ は acceptance-guard.sh を含むので別に書き出す(D44 (b))
  git -C "$repo" archive "$tree" -- . ':(exclude,icase)*acceptance*' | tar -x -C "$ws"
  git -C "$repo" archive "$tree" -- .claude/hooks | tar -x -C "$ws"

  # 規約スキルを写す(D47 (a))。SKILL.md と references/ だけ(評価の出力などは写さない)
  local src dst
  for s in "${rule_skills[@]}"; do
    src="$HOME/.claude/skills/$s"
    dst="$ws/.claude/skills/$s"
    mkdir -p "$dst"
    cp -L "$src/SKILL.md" "$dst/SKILL.md"
    if [ -d "$src/references" ]; then
      cp -RL "$src/references" "$dst/references"
    fi
  done

  # スナップショット(ホスト側。マウントの外)
  rm -rf "$snap"
  git -c init.templateDir= init -q --bare "$snap"
  mkdir -p "$snap/info"
  printf '%s\n' '* -text -filter -ident' >"$snap/info/attributes"
  snapgit add -A -f
  snapgit -c user.name=kn-sandbox -c user.email=kn-sandbox@localhost -c commit.gpgsign=false \
    commit -q --no-verify -m "kn-sandbox snapshot"
  snapgit rev-parse HEAD >"$base_dir/base.new"

  # VM の中で kn-implementer が差分を見るための git。VM の中で作る(ホスト側では使わない)
  if vm_exists; then
    sbx --no-input exec -w "$ws" "$vm" git init -q
    sbx --no-input exec -w "$ws" "$vm" git add -A -f
    sbx --no-input exec -w "$ws" "$vm" git -c user.name=kn-sandbox -c user.email=kn-sandbox@localhost \
      commit -q --no-verify -m "kn-sandbox snapshot"
  fi

  mv "$base_dir/base.new" "$base_dir/base"
  echo "kn-sandbox: 作業場所を書き出しました: $ws" >&2
}

cmd_run() {
  [ $# -ge 1 ] || usage
  local prompt_file="$1"
  shift
  local cont=()
  if [ $# -ge 1 ]; then
    [ "$1" = "--continue" ] || usage
    cont=(--continue)
  fi
  [ -f "$prompt_file" ] || die "プロンプトのファイルがありません: $prompt_file"
  [ -f "$base_dir/base" ] || die "作業場所がありません。先に prepare してください"
  vm_exists || die "VM $vm がありません。先に create してください"
  [ -f "$base_dir/created" ] || die "VM $vm の create が終わっていません(GitHub を止めていない可能性があります)。recreate してください"
  local prompt
  prompt="$(cat "$prompt_file")"
  sbx --no-input exec -w "$ws" "$vm" bun install --frozen-lockfile >&2
  # VM は使い捨てなので権限確認は外す。hook(acceptance ガード)はこの指定でも止める
  sbx --no-input exec -w "$ws" "$vm" claude --agent kn-implementer --dangerously-skip-permissions \
    ${cont[@]+"${cont[@]}"} -p "$prompt"
}

cmd_collect() {
  [ -f "$base_dir/base" ] || die "作業場所がありません。先に prepare してください"
  vm_stop
  local base now
  base="$(cat "$base_dir/base")"
  now="$(ws_tree)" || die "作業場所の状態を読めません"
  if [ "$now" = "$(base_tree)" ]; then
    echo "kn-sandbox: 取り込んでいない変更はありません" >&2
    return 0
  fi

  # 取り込めないパスとシンボリックリンク(D47 (d)・D48 (e)(f))。リネームは削除と追加に分けて見る
  local meta p newmode bad=() links=()
  while IFS= read -r -d '' meta && IFS= read -r -d '' p; do
    newmode="$(printf '%s' "$meta" | cut -d' ' -f2)"
    is_forbidden_path "$p" && bad+=("$p")
    [ "$newmode" = "120000" ] && links+=("$p")
  done < <(snapgit diff-index --cached --raw --no-renames -z "$base")
  if [ ${#bad[@]} -gt 0 ]; then
    die "取り込めないパス(受け入れ要件・.claude/・CLAUDE.md・CLAUDE.local.md・.mcp.json・タスクの文書)に触れる変更があるので、何も取り込みません。run --continue で kn-implementer に戻させてから collect し直してください: ${bad[*]}"
  fi
  if [ ${#links[@]} -gt 0 ]; then
    die "シンボリックリンクの追加・変更があるので、何も取り込みません。run --continue で kn-implementer に戻させてから collect し直してください: ${links[*]}"
  fi

  snapgit diff-index --cached -p --binary --no-renames "$base" >"$base_dir/patch"
  if ! git -C "$repo" apply --check --binary "$base_dir/patch" 2>"$base_dir/apply-error"; then
    cat "$base_dir/apply-error" >&2
    die "元の作業ツリーに当てられないので、何も取り込みません。メインが同じ箇所を変えたか、書き出していないファイル(gitignore の対象や、\".\" で始まる未追跡ファイル)と同じパスを kn-implementer が作った可能性があります。メインの変更を戻すか、run --continue で kn-implementer に戻させてから collect し直してください"
  fi
  git -C "$repo" apply --binary "$base_dir/patch"

  # 取り込んだ新しいファイルを記録する(次の prepare で、"." で始まる要素を含むものも書き出すため)
  snapgit diff-index --cached --name-only --no-renames --diff-filter=A -z "$base" |
    tr '\0' '\n' >>"$base_dir/collected"
  # 取り込んだ状態を base にする(続けて run --continue → collect したときに、増えた分だけを当てる)
  advance_base
  git -C "$repo" apply --stat "$base_dir/patch"
}

cmd_rm() {
  if vm_exists; then
    sbx --no-input rm --force "$vm" >&2
  fi
  rm -rf "$base_dir"
  echo "kn-sandbox: VM $vm と置き場所を消しました" >&2
}

case "$cmd" in
  create) cmd_create "$@" ;;
  recreate) cmd_recreate "$@" ;;
  prepare) cmd_prepare "$@" ;;
  run) cmd_run "$@" ;;
  collect) cmd_collect "$@" ;;
  rm) cmd_rm "$@" ;;
  *) usage ;;
esac
