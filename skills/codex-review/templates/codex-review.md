# Codex レビュー基準（プロジェクト固有）

<!--
このファイルをリポジトリ直下に `.codex-review.md` としてコピーし、プロジェクトに合わせて書き換える。
  cp <codex-review のスキルディレクトリ>/templates/codex-review.md .codex-review.md
場所を変える場合: git config codex-review.guide <path>

読み手は2者いる。
  - Codex（レビュー担当）: 最優先のレビュー基準として最初に読む
  - codex-review スキルを実行するエージェント: 指摘の検証（手順3）と修正（手順5）で読む
該当しない節は削除してよい。
-->

## 最初に読むファイル

- `docs/review-guidelines.md`  ← 例: レビュー基準の本体
- `docs/ai-review-lessons.md`  ← 例: 過去に繰り返し出た指摘。同種の問題を優先的に探す
- `backend/AGENTS.md`, `frontend/AGENTS.md`  ← 例: 領域別のルール

## 重点観点

- 例: UI で DOM から要素を消す変更は、仕様が「非表示」なのか「disabled・closed 表示」なのかを `docs/screens/**` で確認する
- 例: API の変更は `docs/api/**` の IF 定義と一致しているか
- 例: マイグレーションファイルは手書きされていないか

## 設計書・仕様の場所

| 変更対象 | 照合する設計書 |
|---|---|
| `src/api/**` | `docs/api/**` |
| `src/models/**` | `docs/models/**` |
| `src/pages/**` | `docs/screens/**` |

## 修正時のルール（エージェント向け）

- 実装前に読む: `docs/ai-review-lessons.md`
- コード変更に対応する設計書を同じ作業単位で更新する（上の表）
- テスト:
  - frontend: `npm run test` と `npm run type-check`
  - backend: `make test`
- 修正した指摘は `docs/ai-review-lessons.md` の更新ルールに従って記録する
