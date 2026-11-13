#!/usr/bin/env bash
#
# install.sh / uninstall.sh のテスト。
#
# HOME を使い捨てディレクトリに差し替えて実行する。実際の ~/.claude などには触れない。
#
# 実行: tests/test_install_sh.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SKILL_SRC="$ROOT/skills/codex-review"

PASS=0
FAIL=0
fail() { echo "  NG: $1"; FAIL=$(( FAIL + 1 )); }
ok() { PASS=$(( PASS + 1 )); }
check() { if eval "$1"; then ok; else fail "$2"; fi; }

abort() { echo "テストの初期化に失敗しました: $1" >&2; exit 1; }

WORK="$(mktemp -d)" || abort "mktemp"
[[ -n "$WORK" && -d "$WORK" ]] || abort "一時ディレクトリが不正 ($WORK)"
trap 'rm -rf "$WORK"' EXIT

# 実際のホームを触らないよう、HOME を差し替えた環境で実行する。
run_install() {
  env -u CODEX_HOME HOME="$FAKE_HOME" PATH="$FAKE_HOME/.local/bin:$PATH" bash "$ROOT/install.sh" "$@" 2>&1
}
run_uninstall() {
  env -u CODEX_HOME HOME="$FAKE_HOME" bash "$ROOT/uninstall.sh" "$@" 2>&1
}

echo "== 自動判定でのインストール =="

FAKE_HOME="$WORK/home1"
mkdir -p "$FAKE_HOME/.claude" "$FAKE_HOME/.agents" || abort "mkdir home1"
out="$(run_install)"; rc=$?
check '[[ $rc -eq 0 ]]' "インストールが成功する ($out)"
check '[[ "$(readlink "$FAKE_HOME/.claude/skills/codex-review")" == "$SKILL_SRC" ]]' "Claude Code のスキルディレクトリへリンクする"
check '[[ "$(readlink "$FAKE_HOME/.agents/skills/codex-review")" == "$SKILL_SRC" ]]' "~/.agents/skills へリンクする"
check '[[ ! -e "$FAKE_HOME/.codex/skills/codex-review" ]]' "~/.agents があれば ~/.codex には重複して入れない"
check '[[ "$(readlink "$FAKE_HOME/.local/bin/codex-review")" == "$SKILL_SRC/bin/codex-review" ]]' "CLI を ~/.local/bin へリンクする"
check '"$FAKE_HOME/.local/bin/codex-review" --help 2>&1 | grep -q "使い方:"' "リンク経由で CLI が動く"

# 2回実行しても壊れない (git pull 後の再実行を想定)。
out="$(run_install)"; rc=$?
check '[[ $rc -eq 0 ]]' "再実行しても成功する ($out)"
check '[[ "$out" == *"インストール済み"* ]]' "再実行ではインストール済みと表示する"

echo "== アンインストール =="

out="$(run_uninstall)"
check '[[ ! -e "$FAKE_HOME/.claude/skills/codex-review" && ! -L "$FAKE_HOME/.claude/skills/codex-review" ]]' "Claude Code のスキルを取り除く"
check '[[ ! -L "$FAKE_HOME/.agents/skills/codex-review" ]]' "~/.agents/skills のスキルを取り除く"
check '[[ ! -L "$FAKE_HOME/.local/bin/codex-review" ]]' "CLI のリンクを取り除く"
check '[[ -f "$SKILL_SRC/SKILL.md" ]]' "リンク元 (このリポジトリ) は消さない"

echo "== コピーでのインストール =="

FAKE_HOME="$WORK/home2"
mkdir -p "$FAKE_HOME" || abort "mkdir home2"
out="$(run_install --dir "$WORK/custom-skills" --copy)"; rc=$?
check '[[ $rc -eq 0 ]]' "--dir --copy が成功する ($out)"
check '[[ -d "$WORK/custom-skills/codex-review" && ! -L "$WORK/custom-skills/codex-review" ]]' "--copy では実ディレクトリとして置く"
check '[[ "$(readlink "$FAKE_HOME/.local/bin/codex-review")" == "$WORK/custom-skills/codex-review/bin/codex-review" ]]' "--copy では CLI がコピー先を指す"
check '"$FAKE_HOME/.local/bin/codex-review" --help >/dev/null 2>&1' "コピー先の CLI が動く"

# コピー済みのものは --force なしでは置き換えない。
out="$(run_install --dir "$WORK/custom-skills" --copy)"; rc=$?
check '[[ $rc -ne 0 ]]' "既存のコピーは --force なしで置き換えない"
out="$(run_install --dir "$WORK/custom-skills" --copy --force)"; rc=$?
check '[[ $rc -eq 0 ]]' "--force で置き換えられる ($out)"

echo "== 無関係なものを壊さない =="

FAKE_HOME="$WORK/home3"
mkdir -p "$FAKE_HOME/.claude/skills/codex-review" || abort "mkdir home3"
echo "unrelated" > "$FAKE_HOME/.claude/skills/codex-review/keep.txt"
out="$(run_install --claude --force)"; rc=$?
check '[[ $rc -ne 0 ]]' "codex-review でないディレクトリは --force でも置き換えない"
check '[[ -f "$FAKE_HOME/.claude/skills/codex-review/keep.txt" ]]' "無関係なディレクトリの中身が残る"
out="$(run_uninstall)"
check '[[ -f "$FAKE_HOME/.claude/skills/codex-review/keep.txt" ]]' "アンインストールでも無関係なディレクトリを消さない"

FAKE_HOME="$WORK/home4"
mkdir -p "$FAKE_HOME" || abort "mkdir home4"
out="$(run_install)"; rc=$?
check '[[ $rc -ne 0 ]]' "ハーネスが見つからなければエラーにする"
check '[[ "$out" == *"--dir"* ]]' "インストール先の指定方法を案内する"

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
