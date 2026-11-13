#!/usr/bin/env bash
#
# codex-review (bin/codex-review) のテスト。
#
# 使い捨ての git リポジトリを作り、コミット範囲の選択と終了コードを固定する。
# ここでの回帰は「レビュー対象が静かに漏れる」形で現れるため、
# 対象コミット数と差分の出し分けを明示的に検証する。
#
# 実行: tests/test_codex_review_sh.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/skills/codex-review/bin/codex-review"
STATE_PY="$ROOT/skills/codex-review/lib/codex_review_state.py"

# 利用者の環境設定がテストへ漏れないようにする。
# ~/.gitconfig に codex-review.base があると、ベース判定のテストが別物になる。
unset CODEX_REVIEW_BASE CODEX_REVIEW_GUIDE CODEX_REVIEW_WORK_DIR CODEX_REVIEW_STATE_DIR \
  CODEX_REVIEW_REQUEST_PATH CODEX_REVIEW_PROMPT_PATH CODEX_REVIEW_RESULT_PATH \
  CODEX_REVIEW_LOG_PATH CODEX_REVIEW_PREFS_PATH CODEX_REVIEW_LANG CODEX_REVIEW_SESSION_ID
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1

PASS=0
FAIL=0

fail() {
  echo "  NG: $1"
  FAIL=$(( FAIL + 1 ))
}

ok() {
  PASS=$(( PASS + 1 ))
}

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  if [[ "$actual" == "$expected" ]]; then
    ok
  else
    fail "${label} (期待: $expected / 実際: $actual)"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    ok
  else
    fail "${label} (「${needle}」が出力に含まれない)"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    fail "${label} (「${needle}」が含まれている)"
  else
    ok
  fi
}

# 初期化は失敗したら即終了する。
# set -e を使っていないため、ガードが無いと mktemp や cd の失敗に気付かないまま
# 開発者の実リポジトリに対して git init / commit / merge を実行してしまう。
abort() {
  echo "テストの初期化に失敗しました: $1" >&2
  exit 1
}

[[ -x "$SCRIPT" ]] || abort "実行できない: $SCRIPT"

# 使い捨てリポジトリを作る。
WORK="$(mktemp -d)" || abort "mktemp"
[[ -n "$WORK" && -d "$WORK" ]] || abort "一時ディレクトリが不正 ($WORK)"
WORK="$(cd "$WORK" && pwd -P)" || abort "realpath $WORK"
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
mkdir -p "$REPO" || abort "mkdir $REPO"
cd "$REPO" || abort "cd $REPO"
# 実リポジトリで操作していないことを確かめてから git を触る。
[[ "$PWD" == "$REPO" ]] || abort "作業ディレクトリが $REPO ではない ($PWD)"
git init -q -b main || abort "git init"
git config user.email t@example.com || abort "git config user.email"
git config user.name tester || abort "git config user.name"

REQUEST="$REPO/.git/codex-review/request.md"
PROMPT_FILE="$REPO/.git/codex-review/prompt.md"

commit() {
  echo "$2" > "$1" || abort "ファイル作成 $1"
  git add "$1" || abort "git add $1"
  git commit -q -m "$3" || abort "git commit $3"
  git rev-parse HEAD
}

C1="$(commit a.txt 1 'first')"
# ベースブランチ。以降のコミットはすべて「ベースとの差分」になる。
git branch -q develop "$C1" || abort "git branch develop"
# このリポジトリの既定ベースを develop にする (git config codex-review.base)。
git config codex-review.base develop || abort "git config codex-review.base"
C2="$(commit b.txt 2 'second')"
C3="$(commit c.txt 3 'third')"

# マージコミットを作る。
git checkout -q -b side "$C1"
SIDE="$(commit d.txt 4 'side')"
git checkout -q main
git merge -q --no-ff side -m 'merge side' >/dev/null
MERGE="$(git rev-parse HEAD)"
C4="$(commit e.txt 5 'fourth')"

# 競合を手作業で解消したマージを作る。競合解消は作成者が書いた差分なので、
# レビュー対象に含まれなければならない。
git checkout -q -b conflicting "$C4"
echo "THEIRS" > conflict.txt
git add conflict.txt || abort "git add conflict.txt"
git commit -q -m "theirs" || abort "git commit theirs"
git checkout -q main
echo "OURS" > conflict.txt
git add conflict.txt || abort "git add conflict.txt (main)"
git commit -q -m "ours" || abort "git commit ours"
git merge conflicting >/dev/null 2>&1
echo "RESOLVED-BY-HAND" > conflict.txt
git add conflict.txt || abort "競合解消の add"
git commit -q -m "merge conflicting" || abort "競合解消マージの commit"
CONFLICT_MERGE="$(git rev-parse HEAD)"

# 本物の codex を絶対に起動しないためのガード。
# スタブを差していない経路が残っていると、テストが実 API を叩いて止まる。
# 個別のテストは自分のスタブを PATH の先頭に足して上書きする。
NO_CODEX_BIN="$WORK/no-codex"
mkdir -p "$NO_CODEX_BIN" || abort "mkdir no-codex"
cat > "$NO_CODEX_BIN/codex" <<'NOCODEX'
#!/usr/bin/env bash
echo "ERROR: テストが本物の codex を起動しようとしました" >&2
exit 97
NOCODEX
chmod +x "$NO_CODEX_BIN/codex" || abort "chmod no-codex"
export PATH="$NO_CODEX_BIN:$PATH"

# codex のスタブ。成功版と失敗版を先に作っておく。
# 定義はセットアップにまとめ、順序に依存しないようにする。
ARGS_LOG="$WORK/codex-args.txt"
OK_BIN="$WORK/okbin"
NG_BIN="$WORK/ngbin"
mkdir -p "$OK_BIN" "$NG_BIN" || abort "mkdir stub bin"
# 受け取った引数を記録する。表示や保存だけを見るテストでは、
# 値が実際に codex へ渡らなくなった退行を検出できない。
{
  echo '#!/usr/bin/env bash'
  echo 'printf "%s\\n" "$@" > "$CODEX_ARGS_LOG"'
  echo 'out=""; args=("$@")'
  echo 'for ((i=0;i<${#args[@]};i++)); do [[ "${args[i]}" == "--output-last-message" ]] && out="${args[i+1]}"; done'
  echo 'printf %s '"'"'{"summary":"stub","findings":[],"verified":[],"remainingRisks":[]}'"'"' > "$out"'
} > "$OK_BIN/codex" || abort "codex スタブ (成功) の作成"
printf '#!/usr/bin/env bash\nexit 1\n' > "$NG_BIN/codex" || abort "codex スタブ (失敗) の作成"
chmod +x "$OK_BIN/codex" "$NG_BIN/codex" || abort "chmod codex スタブ"

export CODEX_REVIEW_STATE_PATH="$WORK/state.json"
run_script() {
  env CODEX_REVIEW_STATE_PATH="$CODEX_REVIEW_STATE_PATH" \
    bash "$SCRIPT" "$@" 2>&1
}

# 特定の範囲だけを対象にする。範囲指定の引数は無いので、
# 終端コミットを HEAD にしてベースを指定する形で同じ範囲を作る。
review_range() {
  local base="$1" head="$2"; shift 2
  local out rc
  git checkout -q "$head" || abort "checkout $head"
  out="$(run_script --base "$base" "$@")"; rc=$?
  git checkout -q main || abort "checkout main"
  printf '%s\n' "$out"
  return $rc
}

target_count() {
  grep -m1 '^- 対象コミット数: ' "$REQUEST" | sed 's/.*: //'
}

# 「指摘をユーザーへ提示したら次を実行してください:」の次の行 (完了コマンド) を、
# このテストのスクリプトで実行できる形に変換する。
completion_cmd() {
  local line rest
  line="$(printf '%s\n' "$1" | sed -n '/指摘をユーザーへ提示したら/{n;p;}')"
  rest="${line#*--complete}"
  [[ "$rest" == "$line" ]] && return 1
  printf 'bash %q --complete%s\n' "$SCRIPT" "$rest"
}

echo "== ロケール依存の変数展開 =="

# "$VAR）" のように変数名の直後に全角文字を置くと、ロケールによっては
# 全角文字まで変数名の一部と解釈され、set -u で落ちる (--status が落ちた)。
# 直後に非 ASCII 文字が続く変数展開は ${VAR} と書く。
unbraced="$(LC_ALL=C grep -nE '\$[A-Za-z_][A-Za-z0-9_]*[^ -~]' "$SCRIPT" | grep -vE '^[0-9]+:[[:space:]]*#')"
if [[ -n "$unbraced" ]]; then
  fail "直後に非 ASCII 文字が続く変数展開がある: $unbraced"
else
  ok
fi

echo "== 使い方 =="

help_out="$(bash "$SCRIPT" --help 2>&1)"; help_rc=$?
assert_eq "$help_rc" "0" "--help は正常終了する"
assert_contains "$help_out" "使い方:" "--help で使い方を表示する"
assert_contains "$help_out" "--complete" "--help にオプションの説明が含まれる"

echo "== ベースとの差分で対象を決める =="

# 既定はベース (git config の develop) との差分。ブランチ上の全コミットが対象になる。
ALL_ON_BRANCH="$(git rev-list --count develop..HEAD)"
out="$(run_script --dry-run)"
assert_eq "$(target_count)" "$ALL_ON_BRANCH" "既定でベースとの差分が全件対象になる"
assert_contains "$out" "ベース: develop [git config codex-review.base]" "使ったベースと出所を表示する"

# 範囲を絞る引数は存在しない。途中だけ未レビューで残る状態を作らせないため。
if run_script -n 2 --dry-run >/dev/null 2>&1; then
  fail "-n が受け付けられてしまう"
else
  ok
fi
if run_script --range "${C1}..${C3}" --dry-run >/dev/null 2>&1; then
  fail "--range が受け付けられてしまう"
else
  ok
fi

# 生成物は .git の中に置く。作業ツリーを汚すと、対象リポジトリに
# .gitignore を足さない限りコミットに混入しうる。
if git status --porcelain | grep -q 'codex-review'; then
  fail "生成物が作業ツリーに出ている"
else
  ok
fi
[[ -f "$REQUEST" ]] && ok || fail "依頼ファイルが .git/codex-review/ に無い"

echo "== ベースの決め方 =="

# git config が無ければ origin/HEAD の指すブランチを使う。
git config --unset codex-review.base || abort "unset codex-review.base"
git update-ref refs/remotes/origin/develop "$C2" || abort "update-ref origin/develop"
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop || abort "symbolic-ref origin/HEAD"
out="$(run_script --dry-run)"
assert_eq "$(target_count)" "$(git rev-list --count ${C2}..HEAD)" \
  "ベース未指定なら origin/HEAD が指すブランチを使う"
assert_contains "$out" "ベース: origin/develop [自動判定]" "自動判定であることを表示する"

# git config は origin/HEAD より優先する (origin/HEAD は古いことがある)。
git config codex-review.base develop || abort "git config codex-review.base"
run_script --dry-run >/dev/null
assert_eq "$(target_count)" "$ALL_ON_BRANCH" "git config codex-review.base が origin/HEAD より優先される"

# 環境変数は git config より優先する。
env CODEX_REVIEW_BASE="$C2" CODEX_REVIEW_STATE_PATH="$CODEX_REVIEW_STATE_PATH" \
  bash "$SCRIPT" --dry-run >/dev/null 2>&1
assert_eq "$(target_count)" "$(git rev-list --count ${C2}..HEAD)" "CODEX_REVIEW_BASE が git config より優先される"

git symbolic-ref --delete refs/remotes/origin/HEAD || abort "symbolic-ref --delete"
git update-ref -d refs/remotes/origin/develop || abort "update-ref -d"

# 自動判定では現在のブランチ自身を候補から外す。
# main ブランチ上で main をベースにすると、差分が常に空になり「対象なし」と誤案内する。
git config --unset codex-review.base || abort "unset codex-review.base"
out="$(run_script --dry-run)"; rc=$?
assert_eq "$rc" "1" "候補が現在のブランチしか無ければベース不明で止まる"
assert_contains "$out" "git config codex-review.base" "ベースの指定方法を案内する"
git checkout -q -b feature "$C4" || abort "checkout feature"
out="$(run_script --dry-run)"
assert_contains "$out" "ベース: main [自動判定]" "別ブランチ上では main を自動判定する"
git checkout -q main || abort "checkout main"
git branch -q -D feature
git config codex-review.base develop || abort "git config codex-review.base"

# --base で比較先を変えられる。
run_script --base "$C2" --dry-run >/dev/null
assert_eq "$(target_count)" "$(git rev-list --count ${C2}..HEAD)" "--base で比較先を変えられる"

# 存在しないベースはエラーで止まる (黙って別の範囲をレビューしない)。
run_script --base no-such-branch --dry-run >/dev/null 2>&1
assert_eq "$?" "1" "存在しないベースはエラー"

# ベースと同じ位置なら対象なしで exit 2。
git checkout -q -b same-as-base develop
run_script --dry-run >/dev/null 2>&1
assert_eq "$?" "2" "ベースと差が無ければ exit 2"
git checkout -q main
git branch -q -D same-as-base

echo "== プロジェクト固有のレビュー基準 =="

run_script --dry-run >/dev/null
assert_not_contains "$(cat "$PROMPT_FILE")" ".codex-review.md" "基準ファイルが無ければプロンプトに出さない"

printf '# 基準\n' > .codex-review.md
run_script --dry-run >/dev/null
assert_contains "$(cat "$PROMPT_FILE")" ".codex-review.md  ← このプロジェクト固有のレビュー基準" \
  "基準ファイルがあれば最優先で読ませる"
rm -f .codex-review.md

mkdir -p docs && printf '# 基準\n' > docs/review.md
git config codex-review.guide docs/review.md || abort "git config codex-review.guide"
run_script --dry-run >/dev/null
assert_contains "$(cat "$PROMPT_FILE")" "docs/review.md  ← このプロジェクト固有のレビュー基準" \
  "git config codex-review.guide で基準ファイルの場所を変えられる"
git config --unset codex-review.guide
rm -rf docs

echo "== マージコミットの競合解消 =="

# 競合解消は作成者が手で書いた差分なので、レビュー対象から漏れてはならない。
review_range "${CONFLICT_MERGE}~1" "${CONFLICT_MERGE}" --dry-run >/dev/null
request="$(cat "$REQUEST")"
if grep -q "^- .$(git rev-parse --short "$CONFLICT_MERGE")." "$REQUEST"; then
  ok
else
  fail "競合解消マージが対象に含まれていない"
fi
assert_contains "$request" "RESOLVED-BY-HAND" "競合解消の内容が差分に出る"
assert_contains "$request" "競合解消差分" "マージ差分であることが明示される"

# 取り込んだ上流変更でレビューが埋もれないこと (first-parent 差分ではない)。
if grep -q "^+upstream" "$REQUEST"; then
  fail "マージが取り込んだ上流変更まで差分に含まれている"
else
  ok
fi

# 競合のないマージは、手作業の変更が無い旨だけを示しノイズにならない。
review_range "${MERGE}~1" "${MERGE}" --dry-run >/dev/null
assert_contains "$(cat "$REQUEST")" "手作業による競合解消は含まれません" \
  "クリーンなマージは競合解消なしと明示される"

# 片側を丸ごと採用した解消は --cc では見えない。捨てた側の変更こそレビュー対象なので、
# 対象に含まれ、かつ捨てた内容が差分に出ることを固定する。
git checkout -q -b take-side "$C4" || abort "git checkout take-side"
echo "THEIRS-KEPT" > takeside.txt
git add takeside.txt || abort "add takeside (theirs)"
git commit -q -m "theirs takeside" || abort "commit theirs takeside"
git checkout -q main
echo "OURS-DISCARDED" > takeside.txt
git add takeside.txt || abort "add takeside (ours)"
git commit -q -m "ours takeside" || abort "commit ours takeside"
git merge take-side >/dev/null 2>&1
echo "THEIRS-KEPT" > takeside.txt   # 片側 (theirs) を丸ごと採用
git add takeside.txt || abort "add takeside 解消"
git commit -q -m "merge take-side" || abort "commit take-side マージ"
TAKE_SIDE_MERGE="$(git rev-parse HEAD)"

review_range "${TAKE_SIDE_MERGE}~1" "${TAKE_SIDE_MERGE}" --dry-run >/dev/null
take_request="$(cat "$REQUEST")"
assert_contains "$take_request" "OURS-DISCARDED" \
  "片側を丸ごと採用した解消で、捨てた側の変更が差分に出る"
if grep -q "手作業による競合解消は含まれません" "$REQUEST"; then
  fail "片側採用の解消が「競合解消なし」と扱われている"
else
  ok
fi

# 競合解消差分を取得できない git では、「解消なし」と断定せずに中止する。
# 取得失敗を空出力と同一視すると、確認できていない解消をレビュー済みにしてしまう。
STUB_BIN="$WORK/stubbin"
mkdir -p "$STUB_BIN" || abort "mkdir stubbin"
real_git="$(command -v git)" || abort "git の場所を特定できない"
{
  echo '#!/usr/bin/env bash'
  echo 'for a in "$@"; do [[ "$a" == "--remerge-diff" ]] && exit 128; done'
  echo "exec $real_git \"\$@\""
} > "$STUB_BIN/git" || abort "git スタブの作成"
chmod +x "$STUB_BIN/git" || abort "chmod git スタブ"

stub_out="$(env -u CLAUDE_CODE_SESSION_ID PATH="$STUB_BIN:$PATH" \
  CODEX_REVIEW_STATE_PATH="$WORK/stub-state.json" \
  bash "$SCRIPT" --base "${TAKE_SIDE_MERGE}~1" --dry-run 2>&1)"
stub_exit=$?
assert_eq "$stub_exit" "1" "競合解消差分を取得できない場合は中止する"
assert_contains "$stub_out" "競合解消差分を取得できませんでした" \
  "取得できない旨がユーザーに伝わる"
# 中止メッセージが、存在しない引数を対処として案内しないこと。
# 案内どおり実行すると「不明な引数」で終わり、復旧手段にならない。
if printf '%s' "$stub_out" | grep -Fq -- "--range"; then
  fail "中止メッセージが存在しない --range を案内している"
else
  ok
fi
if printf '%s' "$stub_out" | grep -Eq -- '(^|[[:space:]])-n([[:space:]]|$)'; then
  fail "中止メッセージが存在しない -n を案内している"
else
  ok
fi
# 代わりに、実際に有効な対処が案内されていること。
assert_contains "$stub_out" "--base" "有効な回避策 (--base) を案内する"
if [[ -f "$WORK/stub-state.json" ]]; then
  fail "取得に失敗した実行が記録されている"
else
  ok
fi

echo "== 差分の出し分け =="

# 連続かつマージ無し → 累積差分
review_range "${C1}" "${C3}" --dry-run >/dev/null
assert_contains "$(cat "$REQUEST")" "## 累積差分" "連続レンジでは累積差分を使う"

# マージを含むレンジ → コミット単位差分（対象外の変更を混入させない）
review_range "${C1}" "${C4}" --dry-run >/dev/null
assert_contains "$(cat "$REQUEST")" "## 差分（コミット単位）" "マージ含むレンジではコミット単位差分に切り替わる"

echo "== 終了コード =="

review_range "${C3}" "${C3}" --dry-run >/dev/null 2>&1
assert_eq "$?" "2" "対象コミットが無い場合は exit 2"

out="$(review_range "${C3}" "${C3}" --dry-run)"
assert_contains "$out" "新しいコミットはありません" "exit 2 で対象指定の案内を出す"

# codex が無ければ、差分を集める前に exit 127 で止まりインストール方法を案内する。
NOCODEX_PATH="$(printf '%s' "$PATH" | tr ':' '\n' | while read -r d; do
  [[ -x "$d/codex" ]] || printf '%s:' "$d"; done)"
nocodex_out="$(env PATH="$NOCODEX_PATH" CODEX_REVIEW_STATE_PATH="$WORK/nocodex-state.json" \
  bash "$SCRIPT" 2>&1)"
assert_eq "$?" "127" "codex が無ければ exit 127"
assert_contains "$nocodex_out" "npm install -g @openai/codex" "codex のインストール方法を案内する"
assert_contains "$nocodex_out" "--dry-run" "codex 無しの代替手段を案内する"

echo "== レビュー済みの除外 =="

# レビューを通していないコミットは --complete で記録できない。
# ここが緩いと、未レビューのコミットを手入力で対象外にできてしまう。
if run_script --complete "$(git rev-parse "$C2")" >/dev/null 2>&1; then
  fail "レビューを通していない SHA が記録できる"
else
  ok
fi

# --dry-run は Codex を起動しないので、記録できる状態にはならない。
review_range "${C1}" "${C3}" --dry-run >/dev/null
assert_eq "$(target_count)" "2" "--complete するまで除外されない"
if run_script --complete "$(git rev-parse "$C2")" >/dev/null 2>&1; then
  fail "--dry-run だけで SHA が記録できる"
else
  ok
fi

# 実際にレビューを通してから --complete すると除外される。
git checkout -q "$C3" || abort "checkout C3"
env PATH="$OK_BIN:$PATH" CODEX_REVIEW_STATE_PATH="$CODEX_REVIEW_STATE_PATH" \
  CODEX_REVIEW_PREFS_PATH="$WORK/excl-prefs.json" CODEX_ARGS_LOG="$ARGS_LOG" \
  bash "$SCRIPT" --base "$C1" >/dev/null 2>&1
git checkout -q main || abort "checkout main"
run_script --complete "$(git rev-parse "$C2")" "$(git rev-parse "$C3")" >/dev/null
review_range "${C1}" "${C3}" --dry-run >/dev/null 2>&1
assert_eq "$?" "3" "全件完了済みなら exit 3"

out="$(review_range "${C1}" "${C3}" --dry-run)"
assert_contains "$out" "--force" "exit 3 で --force を案内する"

# --force で再レビューできる。
review_range "${C1}" "${C3}" --dry-run --force >/dev/null
assert_eq "$(target_count)" "2" "--force で除外を無効化できる"

# 一部だけ完了済みの場合は残りが対象になる。
# C1..C4 のコミットは C2 / C3 / SIDE / MERGE / C4 の5件 (マージも対象に含む)。
# C2 と C3 が完了済みなので残り3件。
review_range "${C1}" "${C4}" --dry-run >/dev/null
assert_eq "$(target_count)" "3" "完了済み2件を除いた残り3件が対象になる"

echo "== 完了対象の限定 (別セッションを巻き込まない) =="

# 記録対象は SHA で明示するので、別セッションの分を巻き込みようがない。
# 記録できるのはレビューを通した SHA だけなので、先に実際のレビューを通す。
STATE2="$WORK/state2.json"
git checkout -q "$C3" || abort "checkout C3"
env PATH="$OK_BIN:$PATH" CODEX_REVIEW_STATE_PATH="$STATE2" \
  CODEX_REVIEW_PREFS_PATH="$WORK/state2-prefs.json" CODEX_ARGS_LOG="$ARGS_LOG" \
  bash "$SCRIPT" --base "${C3}~1" >/dev/null 2>&1
git checkout -q main || abort "checkout main"
CODEX_REVIEW_STATE_PATH="$STATE2" CLAUDE_CODE_SESSION_ID=MINE \
  run_script --complete "$(git rev-parse "$C3")" >/dev/null
listed="$(python3 "$STATE_PY" list "$STATE2" | wc -l | tr -d ' ')"
assert_eq "$listed" "1" "指定した SHA だけが記録される"

recorded_sha="$(python3 "$STATE_PY" list "$STATE2" | cut -f1)"
assert_eq "$recorded_sha" "$(git rev-parse "$C3")" "記録されたのは指定した SHA"

# SHA を指定しない --complete は何も記録せずエラーにする。
# 「直前の実行」を推測すると、別セッションや別範囲の分を巻き込む。
if CODEX_REVIEW_STATE_PATH="$STATE2" run_script --complete >/dev/null 2>&1; then
  fail "SHA 無しの --complete はエラーになる"
else
  ok
fi

echo "== 実行失敗時の案内 =="

# ログにはレビュー依頼の中身がそのまま入るため、資料中の /login などを
# 拾って認証エラーと誤案内しないこと。Codex 自身の ERROR: 行だけを見る。
LIMIT_BIN="$WORK/limitbin"
mkdir -p "$LIMIT_BIN" || abort "mkdir limitbin"
{
  echo '#!/usr/bin/env bash'
  echo 'echo "参考資料: URL パス (/login /users 等) を大量に誤検出する"'
  echo 'echo "ERROR: You'"'"'ve hit your usage limit. try again at 8:05 PM."'
  echo 'exit 1'
} > "$LIMIT_BIN/codex" || abort "codex スタブ (上限) の作成"
chmod +x "$LIMIT_BIN/codex" || abort "chmod codex スタブ (上限)"

limit_out="$(env -u CLAUDE_CODE_SESSION_ID PATH="$LIMIT_BIN:$PATH" \
  CODEX_REVIEW_STATE_PATH="$WORK/limit-state.json" \
  CODEX_REVIEW_PREFS_PATH="$WORK/limit-prefs.json" \
  bash "$SCRIPT" --base HEAD~1 --force 2>&1)"
limit_exit=$?

assert_eq "$limit_exit" "1" "Codex が失敗したら非ゼロで終了する"
assert_contains "$limit_out" "利用上限" "利用上限であることを案内する"
if [[ "$limit_out" == *"codex login"* ]]; then
  fail "利用上限なのに認証エラーを案内している (ログ中の /login を誤検出)"
else
  ok
fi
if [[ -f "$WORK/limit-state.json" ]]; then
  fail "失敗した実行が記録されている"
else
  ok
fi

echo "== モデル・推論強度の記憶 =="

PREFS="$WORK/prefs.json"

run_with_stub() {
  local bin="$1"; shift
  env -u CLAUDE_CODE_SESSION_ID PATH="$bin:$PATH" \
    CODEX_REVIEW_STATE_PATH="$WORK/pref-state.json" \
    CODEX_REVIEW_PREFS_PATH="$PREFS" \
    CODEX_ARGS_LOG="$ARGS_LOG" \
    bash "$SCRIPT" "$@" 2>&1
}

# codex へ実際に渡った引数を調べる。
args_has() {
  # -- が無いと "--model" が grep のオプションと解釈され、エラー終了が
  # 「見つからなかった」と同じ扱いになり、不在チェックが素通りする。
  grep -Fxq -- "$1" "$ARGS_LOG" 2>/dev/null
}

pref_value() {
  python3 -c "import json,sys
try:
    print(json.load(open(sys.argv[1])).get(sys.argv[2], ''))
except Exception:
    print('')" "$PREFS" "$1"
}

# 今回の指定が、成功後に既定として記憶される。
out="$(run_with_stub "$OK_BIN" --base HEAD~1 --force --model STUB-X --effort low)"
assert_contains "$out" "モデル    : STUB-X [今回の指定]" "指定したモデルが使われる"
assert_eq "$(pref_value model)" "STUB-X" "成功後にモデルが記憶される"
assert_eq "$(pref_value effort)" "low" "成功後に推論強度が記憶される"
args_has "STUB-X" && ok || fail "指定したモデルが codex の引数に渡らない"
args_has "--model" && ok || fail "args_has が --model を検出できない (grep のオプション解釈)"
args_has 'model_reasoning_effort="low"' && ok || fail "指定した推論強度が codex の引数に渡らない"
args_has "read-only" && ok || fail "codex が read-only で起動されていない"

# 次回は指定を省略しても記憶した値が使われる。
out="$(run_with_stub "$OK_BIN" --base HEAD~1 --force)"
assert_contains "$out" "モデル    : STUB-X [前回の指定を記憶]" "記憶した既定が使われる"
args_has "STUB-X" && ok || fail "記憶したモデルが codex の引数に渡らない"
args_has 'model_reasoning_effort="low"' && ok || fail "記憶した推論強度が codex の引数に渡らない"

# 片方だけ指定すると、もう片方の記憶は保たれる。
out="$(run_with_stub "$OK_BIN" --base HEAD~1 --force --model STUB-Y)"
assert_eq "$(pref_value model)" "STUB-Y" "指定した側は上書きされる"
assert_eq "$(pref_value effort)" "low" "指定しなかった側の記憶は残る"
args_has "STUB-Y" && ok || fail "上書きしたモデルが codex の引数に渡らない"
args_has 'model_reasoning_effort="low"' && ok || fail "記憶側の推論強度が codex の引数に渡らない"

# 失敗した実行は記憶しない。起動できないモデルを既定にすると以降が全部失敗する。
run_with_stub "$NG_BIN" --base HEAD~1 --force --model STUB-BAD >/dev/null 2>&1
assert_eq "$(pref_value model)" "STUB-Y" "失敗した実行のモデルは記憶しない"

# --dry-run は Codex を起動しないので記憶しない。
run_with_stub "$OK_BIN" --base HEAD~1 --force --dry-run --model STUB-DRY >/dev/null 2>&1
assert_eq "$(pref_value model)" "STUB-Y" "--dry-run のモデルは記憶しない"

# --reset-defaults で記憶を消すと config.toml の既定へ戻る。
run_with_stub "$OK_BIN" --reset-defaults >/dev/null 2>&1
out="$(run_with_stub "$OK_BIN" --base HEAD~1 --force)"
assert_contains "$out" "[~/.codex/config.toml]" "リセット後は config.toml の既定に戻る"
args_has "--model" && fail "リセット後もモデルが codex へ渡っている" || ok
if grep -q "model_reasoning_effort" "$ARGS_LOG" 2>/dev/null; then
  fail "リセット後も推論強度が codex へ渡っている"
else
  ok
fi

echo "== 完了コマンドの案内 =="

# レビュー後に表示される完了コマンドは、対象 SHA を埋めた「そのまま使える」形であること。
# 対象を SHA で明示するので、並行実行や別セッションがあっても取り違えようがない。
ID_STATE="$WORK/guide-state.json"
guide_out="$(env CLAUDE_CODE_SESSION_ID=SIDX PATH="$OK_BIN:$PATH" \
  CODEX_REVIEW_STATE_PATH="$ID_STATE" \
  CODEX_REVIEW_PREFS_PATH="$WORK/guide-prefs.json" \
  CODEX_ARGS_LOG="$ARGS_LOG" \
  bash "$SCRIPT" --base HEAD~1 --force 2>&1)"
head_sha="$(git rev-parse HEAD)"
assert_contains "$guide_out" "--complete" "完了コマンドを表示する"
assert_contains "$guide_out" "$head_sha" "完了コマンドに対象 SHA が入っている"

# Codex が成功しただけでは記録しない (提示前に中断されても対象に残る)。
assert_eq "$(python3 "$STATE_PY" list "$ID_STATE" | wc -l | tr -d ' ')" "0" \
  "レビュー実行だけでは記録しない"

# 表示されたコマンドをそのまま実行すると、その SHA だけが記録される。
guide_cmd="$(completion_cmd "$guide_out")" || fail "完了コマンドを読み取れない"
eval "env CODEX_REVIEW_STATE_PATH=\"$ID_STATE\" CLAUDE_CODE_SESSION_ID=SIDX $guide_cmd" >/dev/null
# 対象がマージコミットの場合、範囲には取り込んだ側のコミットも含まれる。
# 記録されるのは「その実行が対象にした SHA 全部」であって 1 件とは限らない。
expected_shas="$(git rev-list HEAD~1..HEAD | sort | tr '\n' ' ')"
recorded_shas="$(python3 "$STATE_PY" list "$ID_STATE" | cut -f1 | sort | tr '\n' ' ')"
assert_eq "$recorded_shas" "$expected_shas" "表示されたコマンドで対象 SHA が記録される"

# 指摘件数は --status の表示に使うので、完了コマンドで引き継がれること。
assert_contains "$guide_out" "--findings" "完了コマンドに指摘件数を引き継ぐ"

# 状態ファイルの更新が並行しても失われないこと。
# 逐次に呼ぶだけのテストでは read-modify-write の競合を検出できない
# (ロック無しの実装でも通ってしまう)。実際に同時実行して確かめる。
RACE_STATE="$WORK/race-state.json"
printf '%s\n' '{"version":2,"reviewed":{},"pending":{}}' > "$RACE_STATE"
RACE_N=30
for i in $(seq 1 "$RACE_N"); do
  printf 'racesha%03d\n' "$i" \
    | python3 "$STATE_PY" pend "$RACE_STATE" --session R >/dev/null &
done
wait
race_pending="$(python3 -c "
import json, sys
print(len(json.load(open(sys.argv[1]))['pending']))" "$RACE_STATE")"
assert_eq "$race_pending" "$RACE_N" "並行 pend で更新が失われない"

# record 側も同じ経路なので同時実行で確かめる。
python3 -c "
import json, sys
n = int(sys.argv[2])
json.dump({'version': 2, 'reviewed': {}, 'pending': {'racesha%03d' % i: {'reviewedAt': 'x'} for i in range(1, n + 1)}}, open(sys.argv[1], 'w'))" "$RACE_STATE" "$RACE_N"
for i in $(seq 1 "$RACE_N"); do
  printf 'racesha%03d\n' "$i" \
    | python3 "$STATE_PY" record "$RACE_STATE" --session R >/dev/null &
done
wait
race_reviewed="$(python3 -c "
import json, sys
print(len(json.load(open(sys.argv[1]))['reviewed']))" "$RACE_STATE")"
assert_eq "$race_reviewed" "$RACE_N" "並行 record で更新が失われない"

# 同一セッションの並行実行でも取り違えない。対象が SHA で固定されているため、
# 後発の実行が先行実行の対象を書き換えることがない。
CONC_STATE="$WORK/concurrent-state.json"
run_in_session() {
  env CLAUDE_CODE_SESSION_ID=FIXED PATH="$OK_BIN:$PATH" \
    CODEX_REVIEW_STATE_PATH="$CONC_STATE" \
    CODEX_REVIEW_PREFS_PATH="$WORK/conc-prefs.json" \
    CODEX_ARGS_LOG="$ARGS_LOG" \
    bash "$SCRIPT" "$@" 2>&1
}
run_in_session_range() {
  local base="$1" head="$2"
  local out
  git checkout -q "$head" || abort "checkout $head"
  out="$(run_in_session --base "$base" --force)"
  git checkout -q main || abort "checkout main"
  printf '%s\n' "$out"
}
conc1="$(run_in_session_range "${C1}" "${C2}")"
conc2="$(run_in_session_range "${C2}" "${C3}")"
assert_contains "$conc1" "$(git rev-parse "$C2")" "先行実行は自分の対象を案内する"
assert_contains "$conc2" "$(git rev-parse "$C3")" "後発実行は自分の対象を案内する"

# 先行実行の分だけを記録しても、後発実行の対象は残る。
env CODEX_REVIEW_STATE_PATH="$CONC_STATE" CLAUDE_CODE_SESSION_ID=FIXED \
  bash "$SCRIPT" --complete "$(git rev-parse "$C2")" >/dev/null
assert_eq "$(python3 "$STATE_PY" list "$CONC_STATE" | wc -l | tr -d ' ')" "1" \
  "先行実行の分だけが記録される"

# コミット 0 件 (--dirty のみ) の実行は記録する対象が無いので、その旨を伝える。
ZERO_STATE="$WORK/zero-state.json"
# ベースと同じ位置のブランチなら対象コミットは 0 件。--dirty だけが残る。
git checkout -q -b zero-branch develop || abort "checkout zero-branch"
echo "dirty" > dirty.txt
zero_out="$(env CLAUDE_CODE_SESSION_ID=SIDZ PATH="$OK_BIN:$PATH" \
  CODEX_REVIEW_STATE_PATH="$ZERO_STATE" \
  CODEX_REVIEW_PREFS_PATH="$WORK/zero-prefs.json" \
  CODEX_ARGS_LOG="$ARGS_LOG" \
  bash "$SCRIPT" --dirty --force 2>&1)"
rm -f dirty.txt
git checkout -q main || abort "checkout main"
git branch -q -D zero-branch
assert_contains "$zero_out" "記録は不要" "コミット 0 件なら記録不要と伝える"

echo "== インストール形態 (シンボリックリンク経由・ワークツリー) =="

# ~/.local/bin などへのシンボリックリンク経由でも、同梱の lib/ を見つけられること。
LINK_BIN="$WORK/linkbin"
mkdir -p "$LINK_BIN" || abort "mkdir linkbin"
ln -s "$SCRIPT" "$LINK_BIN/codex-review" || abort "ln -s"
link_out="$(env PATH="$LINK_BIN:$OK_BIN:$PATH" CODEX_REVIEW_STATE_PATH="$WORK/link-state.json" \
  CODEX_REVIEW_PREFS_PATH="$WORK/link-prefs.json" CODEX_ARGS_LOG="$ARGS_LOG" \
  codex-review --base HEAD~1 --force 2>&1)"
assert_eq "$?" "0" "シンボリックリンク経由で起動できる"
# PATH 上の codex-review が自分自身なら、案内はコマンド名で出す。
assert_contains "$link_out" "  codex-review --complete" "PATH 経由ならコマンド名で完了コマンドを案内する"

# PATH に無い場合は、実体のパスで案内する (案内どおりに実行して動くこと)。
assert_contains "$guide_out" "$SCRIPT --complete" "PATH に無ければ実体のパスで案内する"

# ワークツリーでは生成物をワークツリーごとに分け、レビュー済みの記録は共有する。
WT="$WORK/wt"
git worktree add -q -b wt-branch "$WT" "$C4" >/dev/null 2>&1 || abort "git worktree add"
(
  cd "$WT" || exit 1
  env -u CODEX_REVIEW_STATE_PATH bash "$SCRIPT" --base develop --dry-run >/dev/null 2>&1
)
wt_gitdir="$(git -C "$WT" rev-parse --absolute-git-dir)"
[[ -f "$wt_gitdir/codex-review/request.md" ]] && ok || fail "ワークツリーの依頼ファイルがワークツリー専用の場所に無い"
(
  cd "$WT" || exit 1
  env -u CODEX_REVIEW_STATE_PATH PATH="$OK_BIN:$PATH" CODEX_ARGS_LOG="$ARGS_LOG" \
    CODEX_REVIEW_PREFS_PATH="$WORK/wt-prefs.json" \
    bash "$SCRIPT" --base "${C4}~1" >/dev/null 2>&1
  env -u CODEX_REVIEW_STATE_PATH bash "$SCRIPT" --complete "$C4" >/dev/null 2>&1
)
[[ -f "$REPO/.git/codex-review/state.json" ]] && ok || fail "ワークツリーの記録が共通の場所に無い"
shared_status="$(env -u CODEX_REVIEW_STATE_PATH bash "$SCRIPT" --status 2>&1)"
assert_contains "$shared_status" "${C4:0:9}" "別ワークツリーで記録したコミットが本体からも見える"
git worktree remove --force "$WT" >/dev/null 2>&1

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
