#!/usr/bin/env bash
#
# codex-review のインストーラ。
#
# スキル (skills/codex-review) を各ハーネスのスキルディレクトリへ配置し、
# CLI (codex-review) を PATH の通ったディレクトリへリンクする。
#
# 使い方:
#   ./install.sh                 # 見つかったハーネスへ自動でインストールする
#   ./install.sh --claude        # Claude Code (~/.claude/skills)
#   ./install.sh --agents        # Agent Skills 共通の場所 (~/.agents/skills。Codex など)
#   ./install.sh --codex         # Codex (${CODEX_HOME:-~/.codex}/skills)
#   ./install.sh --dir <path>    # 任意のスキルディレクトリ (他のハーネスやプロジェクト内)
#   ./install.sh --bin-dir <path># CLI のリンク先 (既定 ~/.local/bin)
#   ./install.sh --no-bin        # CLI を PATH へリンクしない
#   ./install.sh --copy          # シンボリックリンクではなくコピーで配置する
#   ./install.sh --force         # 既存の codex-review を置き換える
#
# 既定はシンボリックリンク。このリポジトリを git pull すれば全ハーネスに反映される。
# このリポジトリを消す予定がある場合は --copy を使う。
#
# 自動判定では ~/.claude があれば --claude、~/.agents があれば --agents、
# ~/.agents が無く ~/.codex があれば --codex を選ぶ。

set -euo pipefail

NAME="codex-review"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_SRC="$REPO_DIR/skills/$NAME"

TARGETS=()
BIN_DIR="$HOME/.local/bin"
INSTALL_BIN=1
MODE="link"
FORCE=0

usage() {
  awk 'NR < 3 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

die() {
  echo "エラー: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --claude) TARGETS+=("$HOME/.claude/skills"); shift ;;
    --agents) TARGETS+=("$HOME/.agents/skills"); shift ;;
    --codex)  TARGETS+=("${CODEX_HOME:-$HOME/.codex}/skills"); shift ;;
    --dir)    [[ -n "${2:-}" ]] || die "--dir にはパスが必要です"; TARGETS+=("$2"); shift 2 ;;
    --bin-dir) [[ -n "${2:-}" ]] || die "--bin-dir にはパスが必要です"; BIN_DIR="$2"; shift 2 ;;
    --no-bin) INSTALL_BIN=0; shift ;;
    --copy)   MODE="copy"; shift ;;
    --force)  FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "不明な引数: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[[ -f "$SKILL_SRC/SKILL.md" ]] || die "スキルが見つかりません: $SKILL_SRC"

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  [[ -d "$HOME/.claude" ]] && TARGETS+=("$HOME/.claude/skills")
  if [[ -d "$HOME/.agents" ]]; then
    TARGETS+=("$HOME/.agents/skills")
  elif [[ -d "${CODEX_HOME:-$HOME/.codex}" ]]; then
    TARGETS+=("${CODEX_HOME:-$HOME/.codex}/skills")
  fi
  if [[ ${#TARGETS[@]} -eq 0 ]]; then
    die "インストール先のハーネスが見つかりません。--claude / --agents / --codex / --dir <path> で指定してください。"
  fi
  echo "インストール先を自動判定しました: ${TARGETS[*]}"
fi

# 既存のものが codex-review のスキルかどうか。無関係なディレクトリを消さないための確認。
is_codex_review_skill() {
  [[ -f "$1/SKILL.md" ]] && grep -q "^name: ${NAME}\$" "$1/SKILL.md"
}

INSTALLED=()

install_skill() {
  local parent="$1" dest current
  dest="$parent/$NAME"
  mkdir -p "$parent"

  if [[ -L "$dest" ]]; then
    current="$(readlink "$dest")"
    if [[ "$MODE" == "link" && "$current" == "$SKILL_SRC" ]]; then
      echo "インストール済み: $dest -> $SKILL_SRC"
      INSTALLED+=("$dest")
      return
    fi
    [[ "$FORCE" -eq 1 ]] || die "既に存在します: $dest -> $current（置き換える場合は --force）"
    rm "$dest"
  elif [[ -e "$dest" ]]; then
    [[ "$FORCE" -eq 1 ]] || die "既に存在します: $dest（置き換える場合は --force）"
    is_codex_review_skill "$dest" || die "codex-review のスキルではないため置き換えません: $dest"
    rm -rf "$dest"
  fi

  if [[ "$MODE" == "link" ]]; then
    ln -s "$SKILL_SRC" "$dest"
    echo "リンクしました: $dest -> $SKILL_SRC"
  else
    cp -R "$SKILL_SRC" "$dest"
    echo "コピーしました: $dest"
  fi
  INSTALLED+=("$dest")
}

for target in "${TARGETS[@]}"; do
  install_skill "$target"
done

if [[ "$INSTALL_BIN" -eq 1 ]]; then
  # コピーで配置した場合は、このリポジトリが消えても動くよう配置先の CLI を指す。
  if [[ "$MODE" == "link" ]]; then
    bin_target="$SKILL_SRC/bin/$NAME"
  else
    bin_target="${INSTALLED[0]}/bin/$NAME"
  fi
  mkdir -p "$BIN_DIR"
  bin_link="$BIN_DIR/$NAME"
  if [[ -e "$bin_link" && ! -L "$bin_link" ]]; then
    [[ "$FORCE" -eq 1 ]] || die "既に存在します: $bin_link（置き換える場合は --force）"
  fi
  ln -sfn "$bin_target" "$bin_link"
  echo "CLI をリンクしました: $bin_link -> $bin_target"
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
      echo
      echo "注意: $BIN_DIR が PATH に含まれていません。シェルの設定に次を追加してください:"
      echo "  export PATH=\"$BIN_DIR:\$PATH\""
      echo "（PATH に無くても、スキルは同梱の bin/$NAME を直接実行するので動作します）"
      ;;
  esac
fi

# 前提ツールの確認。足りなくてもインストール自体は終える (警告のみ)。
echo
echo "前提ツールの確認:"
if command -v git >/dev/null 2>&1; then
  read -r git_major git_minor <<< "$(git --version | sed -E 's/^git version ([0-9]+)\.([0-9]+).*/\1 \2/')"
  if (( git_major > 2 || (git_major == 2 && git_minor >= 36) )); then
    echo "  OK  git $git_major.$git_minor"
  else
    echo "  NG  git $git_major.$git_minor（2.36 以上が必要。マージコミットのレビューに git show --remerge-diff を使うため）"
  fi
else
  echo "  NG  git が見つかりません"
fi
if command -v python3 >/dev/null 2>&1; then
  echo "  OK  $(python3 --version 2>&1)"
else
  echo "  NG  python3 が見つかりません"
fi
if command -v codex >/dev/null 2>&1; then
  echo "  OK  $(codex --version 2>/dev/null | head -1)"
else
  echo "  --  codex CLI が見つかりません。レビューの実行に必要です:"
  echo "        npm install -g @openai/codex && codex login"
fi

echo
echo "完了しました。ハーネスを再起動すると codex-review スキルが使えます。"
echo "プロジェクト固有のレビュー基準を置く場合: cp $SKILL_SRC/templates/codex-review.md <リポジトリ>/.codex-review.md"
