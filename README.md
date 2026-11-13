# codex-review

ブランチ上の**未レビューのコミット**を [Codex CLI](https://github.com/openai/codex) に read-only でレビューさせ、
呼び出し側の AI エージェント（Claude Code など）が**各指摘を実コードで検証**してから、妥当性の判定と修正案を
ユーザーに提示するスキルです。修正はユーザーが承認した指摘だけを、承認後に実装します。

「実装した AI が自分のコードを自分でレビューして承認する」状態を避け、作成者とレビュー担当を分離するための仕組みです。

## 特徴

- **レビュー漏れを起こさない対象選択**: 対象は「ベースブランチとの差分にある全コミット − レビュー済みの SHA」。
  範囲を絞る引数（`-n` / `--range`）は意図的に用意していません
- **同じコミットを二度レビューしない**: 指摘をユーザーへ提示し終えたコミットだけを SHA で記録します。
  提示前に中断した場合は記録されず、次回また対象になります
- **マージコミットの競合解消もレビュー**: `git show --remerge-diff` で手作業の競合解消だけを抽出します
- **Codex の指摘を鵜呑みにしない**: エージェントが指摘ごとに実コード・設計書で裏を取り、
  「妥当 / 部分的に妥当 / 誤検知」に分類して根拠つきで提示します
- **ハーネス非依存**: [Agent Skills](https://agentskills.io) 形式（`SKILL.md`）なので、Claude Code・Codex など
  スキルに対応したハーネスで使えます。CLI 単体でも動きます
- **対象リポジトリを汚さない**: 生成物と記録は `.git/codex-review/` に置くため、`.gitignore` の追加は不要です

## 必要なもの

| ツール | 用途 |
|---|---|
| git 2.36 以上 | `git show --remerge-diff` を使うため |
| python3（標準ライブラリのみ） | レビュー記録の管理 |
| bash | CLI 本体 |
| [Codex CLI](https://github.com/openai/codex)（`npm install -g @openai/codex` → `codex login`） | レビューの実行。`--dry-run` だけなら不要 |

macOS・Linux で動作します（Windows は WSL を使ってください）。

## インストール

### 方法1: インストーラ（Claude Code・Codex・その他のハーネス共通）

```bash
git clone <このリポジトリの URL> ~/codex-review
cd ~/codex-review
./install.sh
```

`./install.sh` は見つかったハーネスを自動判定し、スキルをシンボリックリンクで配置して、
CLI `codex-review` を `~/.local/bin` にリンクします。`git pull` するだけで全ハーネスに更新が反映されます。

| オプション | 配置先 |
|---|---|
| `--claude` | Claude Code: `~/.claude/skills/codex-review` |
| `--agents` | Agent Skills 共通の場所: `~/.agents/skills/codex-review`（Codex などが読む） |
| `--codex` | Codex: `${CODEX_HOME:-~/.codex}/skills/codex-review` |
| `--dir <path>` | 任意のスキルディレクトリ（他のハーネスや、リポジトリ内の `.claude/skills` など） |
| `--bin-dir <path>` | CLI のリンク先（既定 `~/.local/bin`） |
| `--no-bin` | CLI を PATH にリンクしない |
| `--copy` | リンクではなくコピーで配置する（clone したディレクトリを消す場合） |
| `--force` | 既存の codex-review を置き換える |

自動判定では、`~/.claude` があれば `--claude`、`~/.agents` があれば `--agents`、
`~/.agents` が無く `~/.codex` があれば `--codex` を選びます。インストール後はハーネスを再起動してください。

アンインストール: `./uninstall.sh`（各リポジトリの `.git/codex-review/` は消しません）

### 方法2: Claude Code のプラグインとして

このリポジトリは Claude Code のプラグイン兼マーケットプレイスになっています。

```bash
claude plugin marketplace add <このリポジトリの URL またはローカルパス>
claude plugin install codex-review@codex-review
```

プラグインとして入れた場合、スキル名は `/codex-review:codex-review` になります。
CLI は PATH に入りませんが、スキルが同梱の `bin/codex-review` を直接実行するので動作します。

### 方法3: その他のハーネス・手動

`skills/codex-review/` ディレクトリをそのまま、使っているハーネスのスキルディレクトリへ置いてください
（`./install.sh --dir <そのディレクトリ>` と同じです）。
スキルに対応していないハーネスでは、エージェントに
「`skills/codex-review/SKILL.md` の手順に従ってレビューして」と指示すれば同じ流れで動きます。

## 使い方

### エージェントから使う（通常の使い方）

作業ブランチで、エージェントに次のように依頼します。

```
/codex-review
/codex-review --base origin/develop
Codex にレビューさせて
```

エージェントは次の順に進めます。

1. `codex-review` を実行して Codex にレビューさせる（数分かかります）
2. Codex の指摘を1件ずつ実コード・設計書で検証し、「妥当 / 部分的に妥当 / 誤検知」に分類する
3. 指摘一覧と修正方針を提示し、どれを直すかをユーザーに確認する（この時点ではコードを変更しない）
4. 提示し終えたコミットをレビュー済みとして記録する
5. ユーザーが承認した指摘だけを修正する

### CLI を直接使う

```bash
codex-review                  # ベースとの差分のうち未レビュー分をレビュー
codex-review --base main      # 比較するベースブランチを変える
codex-review --dirty          # 未コミットの変更も含める
codex-review --dry-run        # 依頼ファイルとプロンプトの生成だけ（codex 不要）
codex-review --status         # レビュー済みとして記録したコミットの一覧
codex-review --force          # レビュー済みも含めて再レビュー
codex-review --model <name> --effort <level>   # 成功後は既定として記憶される
codex-review --reset-defaults # 記憶したモデル・推論強度を消す
codex-review --help
```

`--dry-run` で作った `.git/codex-review/request.md` と `prompt.md` は、他の AI や人間のレビュー担当へそのまま渡せます。

| 終了コード | 意味 |
|---|---|
| `0` | 正常終了 |
| `1` | ベースが特定できない・git が古い・Codex の出力が不正 など |
| `2` | ベースとの差分にコミットが無い |
| `3` | 対象コミットがすべてレビュー済み |
| `127` | codex CLI が見つからない |

## リポジトリごとの設定

### ベースブランチ

次の順で決まります。実行時に「ベース: X [出所]」と表示されます。

1. `--base <ref>`
2. 環境変数 `CODEX_REVIEW_BASE`
3. `git config codex-review.base`
4. 自動判定: `origin/HEAD` が指すブランチ → `origin/main` → `origin/master` → `main` → `master`（現在のブランチは除く）

`develop` を基点に開発しているリポジトリなどでは、リポジトリごとに固定しておくと確実です。

```bash
git config codex-review.base origin/develop
```

ローカルのブランチや `origin/HEAD` が古いと、取り込み済みの上流コミットまで未レビューに見えます。
対象件数が多すぎるときは `git fetch` してください（`origin/HEAD` の更新は `git remote set-head origin -a`）。

### プロジェクト固有のレビュー基準（`.codex-review.md`）

リポジトリ直下に `.codex-review.md` を置くと、Codex はそれを最優先のレビュー基準として読みます。
エージェントも、指摘の検証と修正のときにこのファイルの設計書の場所・テスト方法・修正ルールに従います。

```bash
cp ~/codex-review/skills/codex-review/templates/codex-review.md .codex-review.md
git config codex-review.guide docs/review.md   # 別の場所に置く場合
```

置かなくても、Codex はリポジトリの `AGENTS.md` / `CLAUDE.md` / `CONTRIBUTING.md` を読んでレビューします。

### 環境変数

| 変数 | 既定 | 内容 |
|---|---|---|
| `CODEX_REVIEW_BASE` | — | ベースブランチ |
| `CODEX_REVIEW_GUIDE` | `.codex-review.md` | プロジェクト固有のレビュー基準のパス |
| `CODEX_REVIEW_LANG` | `ja` | Codex の出力言語 |
| `CODEX_REVIEW_MAX_DIFF_BYTES` | `400000` | 差分の切り詰めサイズ（Codex は続きを自分で `git show` する） |
| `CODEX_REVIEW_WORK_DIR` | `<git-dir>/codex-review` | 依頼・結果・ログの置き場所（ワークツリーごと） |
| `CODEX_REVIEW_STATE_DIR` | `<git-common-dir>/codex-review` | レビュー記録とモデルの記憶の置き場所（ワークツリー間で共有） |

## ファイルの置き場所

| ファイル | 内容 |
|---|---|
| `.git/codex-review/request.md` | Codex に渡したレビュー対象（対象コミットと差分） |
| `.git/codex-review/prompt.md` | Codex への指示（`--dry-run` 時） |
| `.git/codex-review/result.json` | Codex の構造化レビュー結果 |
| `.git/codex-review/raw.log` | Codex の実行ログ |
| `.git/codex-review/state.json` | レビュー済みコミットの記録（手で編集しない） |
| `.git/codex-review/prefs.json` | 記憶したモデル・推論強度 |

ワークツリーでは、依頼・結果・ログはワークツリー専用の git ディレクトリに、記録は本体の `.git` に置かれます。

## 仕組み

### レビュー済みの記録

1. レビューが成功すると、対象 SHA が「提示待ち」として積まれる（まだ除外されない）
2. エージェントが指摘をユーザーへ提示し終えたら、表示された `codex-review --complete <sha>...` を実行する
3. ここで初めて「レビュー済み」になり、次回以降の対象から外れる

- 記録できるのは実際にレビューを通した SHA だけです。任意の SHA を手入力で除外することはできません
- 一部でも対象外の SHA が混ざると、何も記録しません
- 状態ファイルが壊れていれば「未レビュー」に倒れます（再レビューが増えるだけで、レビュー漏れは起きません）
- 状態ファイルの更新はファイルロックで直列化しており、並行実行しても記録は失われません

### 差分の見せ方

- 対象コミットが連続していてマージを含まない場合は、累積差分を1つ提示します
- それ以外（レビュー済みが間に挟まる、マージを含む）はコミット単位の差分にし、対象外の変更を混ぜません
- マージコミットは `--remerge-diff` で手作業の競合解消だけを示します。`--cc` は片側を丸ごと採用した解消が
  見えないため使いません。`--remerge-diff` が使えない git では、確認できない解消を「解消なし」と
  扱わないよう中止します

## 開発

```bash
tests/run_tests.sh
```

| テスト | 対象 |
|---|---|
| `tests/test_codex_review_state.py` | 記録・除外判定（未記録 / 記録済み / 旧形式 / 不正な値 / 壊れた状態ファイル）、レビュー未実施 SHA の拒否 |
| `tests/test_codex_review_sh.sh` | ベースの決め方、対象選択、差分の出し分け、マージの競合解消、終了コード、モデルの記憶、並行更新、シンボリックリンク経由の起動、ワークツリー |
| `tests/test_install_sh.sh` | インストーラ・アンインストーラ（`HOME` を差し替えて実行） |

テストは本物の codex を起動しません（PATH の先頭に失敗するスタブを置いています）。
対象選択のロジックは、壊れてもエラーにならず「レビュー対象が静かに漏れる」形で現れるため、
変更したら必ずテストを実行してください。

### 構成

```
.
├── install.sh / uninstall.sh
├── .claude-plugin/           Claude Code のプラグイン・マーケットプレイス定義
├── skills/codex-review/      スキル本体（この単位で各ハーネスへ配置する）
│   ├── SKILL.md              エージェント向けの手順
│   ├── bin/codex-review      CLI
│   ├── lib/                  レビュー記録の管理・Codex の出力スキーマ
│   └── templates/            .codex-review.md のひな形
└── tests/
```
