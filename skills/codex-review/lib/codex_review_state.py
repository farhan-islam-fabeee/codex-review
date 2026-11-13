#!/usr/bin/env python3
"""Codex レビュー済みコミットの記録を管理する。

同じコミットを何度も Codex にレビューさせないため、レビュー済みの SHA を
状態ファイル (既定: .git/codex-review/state.json) に記録する。

記録するのは「エージェントが指摘をユーザーへ提示し終えた」時点だけである
(codex-review --complete <sha>...)。Codex の実行が成功した時点では記録しない。
そこで記録すると、検証・提示の前に中断された場合に、指摘が誰にも提示されないまま
除外されてしまう。提示前に中断されれば何も記録されず、次回また対象になる。

完了させる対象は SHA で明示する。以前は実行 ID を発行して「直前の実行で記録した分」を
完了させていたが、どの実行を完了させるかを推測する必要が生まれ、並行実行や別セッションを
取り違えないための規則が積み上がった。提示した SHA をそのまま渡せば取り違えようがない。

記録できるのは、Codex のレビューを実際に通した SHA だけである。
レビュー実行が成功した時点で pending に積み、record はそこに載っている SHA しか受け付けない。
これが無いと、レビューしていないコミットを手入力で「レビュー済み」にでき、
そのコミットは以後の対象から黙って外れる (レビュー漏れ)。

pending に載っているだけでは除外されない。除外されるのは reviewed に移ってからで、
移すのはエージェントが指摘をユーザーへ提示し終えたときだけ。

サブコマンド:
  filter <state>  標準入力の SHA 一覧から、未レビューのものだけを標準出力へ出す
  pend   <state>  レビューを通した SHA を「提示待ち」として積む
  record <state>  提示し終えた SHA をレビュー済みとして記録する (pending に無い SHA は拒否)
  list   <state>  記録済みコミットを TSV で出力する

コミットの内容は不変なので、記録は SHA をキーとする。
指摘を修正して新しくコミットすれば別 SHA になり、次回のレビュー対象になる。
"""

from __future__ import annotations

import argparse
import contextlib
import datetime
import fcntl
import json
import os
import sys
import tempfile

STATE_VERSION = 2

# 二段階記録だった頃の「提示済み」状態。当時の記録を読むときだけ使う。
LEGACY_STATUS_COMPLETED = "completed"


def is_reviewed(meta: object) -> bool:
    """記録がレビュー済みかを返す。

    レビュー済みと認めるのは次の2つだけ。
      - status を持たない記録 (現行形式)
      - status が "completed" の記録 (二段階記録だった頃の提示済み)

    それ以外は未レビューとして扱う。「除外しない値」を列挙する形にすると、
    status が null や未知の文字列になった壊れた記録までレビュー済みになり、
    未提示のコミットを黙って除外してしまう。
    手順書の「壊れていれば未レビューに倒れる」に合わせ、許可リストで判定する。
    """
    if not isinstance(meta, dict):
        return False
    if "status" not in meta:
        return True
    return meta["status"] == LEGACY_STATUS_COMPLETED


def load_state(path: str) -> dict:
    if not os.path.exists(path):
        return {"version": STATE_VERSION, "reviewed": {}, "pending": {}}
    try:
        with open(path, encoding="utf-8") as fh:
            state = json.load(fh)
    except (json.JSONDecodeError, OSError) as exc:
        # 壊れた状態ファイルは「未レビュー扱い」に倒す。
        # 再レビューが増えるだけで、レビュー漏れは起きない。
        print(f"警告: 状態ファイルを読めないため空として扱います ({path}): {exc}", file=sys.stderr)
        return {"version": STATE_VERSION, "reviewed": {}, "pending": {}}

    if not isinstance(state, dict) or not isinstance(state.get("reviewed"), dict):
        print(f"警告: 状態ファイルの形式が不正なため空として扱います ({path})", file=sys.stderr)
        return {"version": STATE_VERSION, "reviewed": {}, "pending": {}}
    # pending が壊れていれば空にする。record が拒否側 (安全側) に倒れるだけ。
    if not isinstance(state.get("pending"), dict):
        state["pending"] = {}
    return state


@contextlib.contextmanager
def locked_state(path: str):
    """状態ファイルの 読み込み→更新→書き込み を直列化する。

    save_state は os.replace で原子的に置き換えるのでファイルが壊れることはないが、
    読み込みから書き込みまでの間に別プロセスが書き込むと、その更新を丸ごと
    上書きしてしまう (実測: 30 並行で pend して 13 件しか残らなかった)。

    手順書は対象コミットが多いときのバックグラウンド実行を認めており、
    並行実行は実運用で起こる。失われた更新は
    「提示したのに記録できない」「不要な再レビュー」として現れる。

    ロックは状態ファイルと別ファイル (<state>.lock) で取る。状態ファイル自体を
    掴むと、os.replace で inode が入れ替わった後のロックが別物になる。
    """
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    with open(path + ".lock", "a+") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def save_state(path: str, state: dict) -> None:
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    # 書き込み中に壊れた状態ファイルを残さないよう、一時ファイル経由で置き換える。
    fd, tmp_path = tempfile.mkstemp(dir=directory, prefix=".codex-review-state-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(state, fh, ensure_ascii=False, indent=2, sort_keys=True)
            fh.write("\n")
        os.replace(tmp_path, path)
    except BaseException:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
        raise


def read_shas(args: argparse.Namespace) -> list[str]:
    """引数で渡された SHA、無ければ標準入力の SHA を読む。"""
    if getattr(args, "shas", None):
        return [s for s in args.shas if s]
    return [line.strip() for line in sys.stdin if line.strip()]


def cmd_filter(args: argparse.Namespace) -> int:
    reviewed = load_state(args.state)["reviewed"]
    for sha in read_shas(args):
        meta = reviewed.get(sha)
        # 記録が無い = 未レビュー。
        if meta is None or not is_reviewed(meta):
            print(sha)
    return 0


def cmd_pend(args: argparse.Namespace) -> int:
    """レビューを通した SHA を「提示待ち」として積む。

    ここに載っただけでは除外されない (filter が見るのは reviewed だけ)。
    record が受け付ける SHA を、実際にレビューを通したものだけに限るための土台。
    """
    shas = read_shas(args)
    now = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
    with locked_state(args.state):
        state = load_state(args.state)
        for sha in shas:
            state["pending"][sha] = {"reviewedAt": now, "sessionId": args.session}
        state["version"] = STATE_VERSION
        save_state(args.state, state)
    print(len(shas))
    return 0


def cmd_record(args: argparse.Namespace) -> int:
    """提示し終えた SHA をレビュー済みとして記録する。

    pending に載っていない SHA は拒否する。レビューを通していないコミットを
    記録できると、そのコミットが以後の対象から黙って外れてレビュー漏れになる。

    一部でも拒否したら何も記録しない。半分だけ記録されると、
    どこまで記録されたのかが利用者から見えなくなる。

    記録した件数を標準出力へ出す。呼び出し側が結果を表示するため。
    """
    shas = read_shas(args)
    now = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
    with locked_state(args.state):
        return _record_locked(args, shas, now)


def _record_locked(args: argparse.Namespace, shas: list[str], now: str) -> int:
    """locked_state の中で呼ばれる record の本体。"""
    state = load_state(args.state)

    # 記録済みの SHA は再指定を許す。完了コマンドを2回流したときに
    # エラーにすると、実際には記録できているのに失敗に見える。
    known = set(state["pending"]) | set(state["reviewed"])
    unknown = [sha for sha in shas if sha not in known]
    if unknown:
        print(
            "レビューを通していないコミットは記録できません:\n  "
            + "\n  ".join(unknown),
            file=sys.stderr,
        )
        print(
            "レビュー実行の最後に表示されたコマンドをそのまま使ってください。",
            file=sys.stderr,
        )
        return 1

    count = 0
    for sha in shas:
        count += 1
        state["reviewed"][sha] = {
            "reviewedAt": now,
            "sessionId": args.session,
            "findings": args.findings,
            "blockers": args.blockers,
        }
        state["pending"].pop(sha, None)
    state["version"] = STATE_VERSION
    # 二段階記録だった頃の実行台帳。もう参照しないので、書き戻すときに捨てる。
    state.pop("lastRun", None)
    save_state(args.state, state)
    print(count)
    return 0


def cmd_list(args: argparse.Namespace) -> int:
    # pending は record が受け付ける SHA を決めるための内部状態なので出さない。
    # --status が示すのは「提示し終えたコミット」だけ、という契約を保つ。
    reviewed = load_state(args.state)["reviewed"]
    for sha, meta in sorted(reviewed.items(), key=lambda kv: str(kv[1].get("reviewedAt", ""))):
        if not isinstance(meta, dict):
            continue
        status = "レビュー済み" if is_reviewed(meta) else "未レビュー(旧形式/不正)"
        print(
            "\t".join(
                [
                    sha,
                    status,
                    str(meta.get("reviewedAt", "")),
                    str(meta.get("findings", "")),
                    str(meta.get("blockers", "")),
                    str(meta.get("sessionId", "")),
                ]
            )
        )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Codex レビュー済みコミットの記録を管理する")
    sub = parser.add_subparsers(dest="command", required=True)

    p_filter = sub.add_parser("filter", help="未レビューの SHA だけを出力する")
    p_filter.add_argument("state")
    p_filter.add_argument("shas", nargs="*")
    p_filter.set_defaults(func=cmd_filter)

    p_pend = sub.add_parser("pend", help="レビューを通した SHA を提示待ちとして積む")
    p_pend.add_argument("state")
    p_pend.add_argument("shas", nargs="*")
    p_pend.add_argument("--session", default="")
    p_pend.set_defaults(func=cmd_pend)

    p_record = sub.add_parser("record", help="提示し終えた SHA をレビュー済みとして記録する")
    p_record.add_argument("state")
    p_record.add_argument("shas", nargs="*")
    p_record.add_argument("--session", default="")
    p_record.add_argument("--findings", default="")
    p_record.add_argument("--blockers", default="")
    p_record.set_defaults(func=cmd_record)

    p_list = sub.add_parser("list", help="記録済みコミットを TSV で出力する")
    p_list.add_argument("state")
    p_list.set_defaults(func=cmd_list)

    # オプションの後ろに並べた SHA も受け付ける (record <state> --session S <sha>... の形)。
    # parse_args では SHA が「不明な引数」として拒否される。parse_intermixed_args は
    # サブコマンドと併用できない (Python 3.9) ため、残った位置引数を SHA として扱う。
    args, extra = parser.parse_known_args()
    unknown_options = [x for x in extra if x.startswith("-")]
    if unknown_options or (extra and not hasattr(args, "shas")):
        parser.error("不明な引数: " + " ".join(extra))
    if extra:
        args.shas = [*(args.shas or []), *extra]
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
