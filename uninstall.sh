#!/usr/bin/env bash
#
# codex-review のアンインストーラ。
#
# install.sh が配置したスキルと CLI のリンクを取り除く。
# 各リポジトリの .git/codex-review/ (レビュー記録など) は消さない。
#
# 使い方:
#   ./uninstall.sh                  # 既定の場所 (~/.claude・~/.agents・~/.codex) から取り除く
#   ./uninstall.sh --dir <path>     # install.sh --dir で入れた場所からも取り除く
#   ./uninstall.sh --bin-dir <path> # CLI のリンク先 (既定 ~/.local/bin)

set -euo pipefail

NAME="codex-review"
PARENTS=("$HOME/.claude/skills" "$HOME/.agents/skills" "${CODEX_HOME:-$HOME/.codex}/skills")
BIN_DIR="$HOME/.local/bin"

usage() {
  awk 'NR < 3 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) PARENTS+=("${2:?--dir にはパスが必要です}"); shift 2 ;;
    --bin-dir) BIN_DIR="${2:?--bin-dir にはパスが必要です}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "不明な引数: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# codex-review のスキルであることを確かめてから消す (無関係なものを消さない)。
is_codex_review_skill() {
  [[ -f "$1/SKILL.md" ]] && grep -q "^name: ${NAME}\$" "$1/SKILL.md"
}

removed=0
for parent in "${PARENTS[@]}"; do
  dest="$parent/$NAME"
  if [[ -L "$dest" ]]; then
    rm "$dest"
    echo "削除しました: $dest"
    removed=$(( removed + 1 ))
  elif [[ -d "$dest" ]]; then
    if is_codex_review_skill "$dest"; then
      rm -rf "$dest"
      echo "削除しました: $dest"
      removed=$(( removed + 1 ))
    else
      echo "codex-review のスキルではないため残しました: $dest" >&2
    fi
  fi
done

bin_link="$BIN_DIR/$NAME"
if [[ -L "$bin_link" ]]; then
  rm "$bin_link"
  echo "削除しました: $bin_link"
  removed=$(( removed + 1 ))
elif [[ -e "$bin_link" ]]; then
  echo "シンボリックリンクではないため残しました: $bin_link" >&2
fi

if [[ "$removed" -eq 0 ]]; then
  echo "取り除くものはありませんでした。"
fi
echo "各リポジトリの .git/codex-review/（レビュー記録など）は残っています。不要なら手で削除してください。"
