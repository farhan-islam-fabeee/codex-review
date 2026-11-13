#!/usr/bin/env bash
#
# codex-review のテストをまとめて実行する。
#
# 実行: tests/run_tests.sh
#
# python は標準ライブラリの unittest のみを使う (追加依存なし)。
# テストは本物の codex を起動しない (PATH の先頭に失敗するスタブを置いて防いでいる)。

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATUS=0

echo "=== python unittest ==="
if ! python3 -m unittest discover -s "$ROOT/tests" -p "test_*.py"; then
  STATUS=1
fi

echo
echo "=== codex-review CLI ==="
if ! bash "$ROOT/tests/test_codex_review_sh.sh"; then
  STATUS=1
fi

echo
echo "=== install.sh / uninstall.sh ==="
if ! bash "$ROOT/tests/test_install_sh.sh"; then
  STATUS=1
fi

echo
if [[ "$STATUS" -eq 0 ]]; then
  echo "すべてのテストが成功しました。"
else
  echo "失敗したテストがあります。" >&2
fi
exit "$STATUS"
