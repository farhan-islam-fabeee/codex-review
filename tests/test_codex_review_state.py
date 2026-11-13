#!/usr/bin/env python3
"""codex_review_state.py のテスト。

このモジュールの回帰はエラーにならず「レビュー対象が静かに漏れる」形で現れるため、
除外判定の境界（未記録 / 記録済み / 旧形式 / 壊れた状態ファイル）を固定する。
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "skills", "codex-review", "lib", "codex_review_state.py",
)


def run(args, stdin=""):
    return subprocess.run(
        [sys.executable, SCRIPT, *args],
        input=stdin,
        capture_output=True,
        text=True,
    )


class StateTestBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state = os.path.join(self.tmp.name, "state.json")
        self.addCleanup(self.tmp.cleanup)

    def filter(self, shas):
        result = run(["filter", self.state], stdin="".join(f"{s}\n" for s in shas))
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.split()

    def pend(self, shas, session="S1"):
        result = run(["pend", self.state, "--session", session], stdin="".join(f"{s}\n" for s in shas))
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def record(self, shas, session="S1", findings="", blockers="", as_args=False, pend_first=True):
        # record はレビューを通した SHA しか受け付けないので、既定では先に積む。
        if pend_first:
            self.pend(shas, session=session)
        args = ["record", self.state, "--session", session, "--findings", findings, "--blockers", blockers]
        if as_args:
            result = run([*args, *shas])
        else:
            result = run(args, stdin="".join(f"{s}\n" for s in shas))
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def write_state(self, payload):
        with open(self.state, "w", encoding="utf-8") as fh:
            json.dump(payload, fh)

    def read_state(self):
        with open(self.state, encoding="utf-8") as fh:
            return json.load(fh)


class TestFilter(StateTestBase):
    def test_未記録のSHAは通る(self):
        self.assertEqual(self.filter(["aaa", "bbb"]), ["aaa", "bbb"])

    def test_記録済みは除外される(self):
        self.record(["aaa"])
        self.assertEqual(self.filter(["aaa", "bbb"]), ["bbb"])

    def test_記録済みでも未記録のSHAは通る(self):
        self.record(["aaa"])
        self.assertEqual(self.filter(["bbb"]), ["bbb"])

    def test_旧形式のstatus無し記録は除外される(self):
        # 二段階にする前の記録。当時は「記録された = レビュー済み」だった。
        self.write_state({"version": 1, "reviewed": {"aaa": {"reviewedAt": "2026-01-01T00:00:00+09:00"}}})
        self.assertEqual(self.filter(["aaa"]), [])

    def test_旧形式の検証待ち記録は除外されない(self):
        # 二段階だった頃の "Codex 実行済みだが未提示"。
        # 提示されていないので除外してはならない (除外すると指摘が失われる)。
        self.write_state({"version": 1, "reviewed": {"aaa": {"status": "codex-done"}}})
        self.assertEqual(self.filter(["aaa"]), ["aaa"])

    def test_旧形式の完了記録は除外される(self):
        self.write_state({"version": 1, "reviewed": {"aaa": {"status": "completed"}}})
        self.assertEqual(self.filter(["aaa"]), [])

    def test_不正なstatus値は未レビュー扱い(self):
        # レビュー済みと認めるのは「status 無し」と "completed" だけ。
        # 「除外しない値の否定」で判定すると、status が壊れた記録まで
        # レビュー済みになり、未提示のコミットを黙って除外する。
        for bad in (None, False, "garbage", 0, []):
            with self.subTest(status=bad):
                self.write_state({"version": 2, "reviewed": {"aaa": {"status": bad}}})
                self.assertEqual(self.filter(["aaa"]), ["aaa"])

    def test_metaが辞書でなければ未レビュー扱い(self):
        self.write_state({"version": 2, "reviewed": {"aaa": "not-a-dict"}})
        self.assertEqual(self.filter(["aaa"]), ["aaa"])

    def test_壊れた状態ファイルは未レビュー扱い(self):
        with open(self.state, "w", encoding="utf-8") as fh:
            fh.write("{ broken")
        self.assertEqual(self.filter(["aaa"]), ["aaa"])

    def test_形式が不正でも未レビュー扱い(self):
        self.write_state({"version": 2, "reviewed": "not-a-dict"})
        self.assertEqual(self.filter(["aaa"]), ["aaa"])

    def test_状態ファイルが無くても落ちない(self):
        self.assertEqual(self.filter(["aaa"]), ["aaa"])


class TestRecord(StateTestBase):
    def test_記録件数を返す(self):
        self.assertEqual(self.record(["aaa", "bbb"]), "2")

    def test_引数でSHAを渡せる(self):
        # --complete <sha>... はコマンドライン引数で渡す。
        self.assertEqual(self.record(["aaa", "bbb"], as_args=True), "2")
        self.assertEqual(self.filter(["aaa", "bbb"]), [])

    def test_記録時刻とセッションが保存される(self):
        self.record(["aaa"], session="S9")
        meta = self.read_state()["reviewed"]["aaa"]
        self.assertEqual(meta["sessionId"], "S9")
        self.assertTrue(meta["reviewedAt"])

    def test_指摘件数が保存される(self):
        self.record(["aaa"], findings="3", blockers="1")
        meta = self.read_state()["reviewed"]["aaa"]
        self.assertEqual(meta["findings"], "3")
        self.assertEqual(meta["blockers"], "1")

    def test_status列は書かない(self):
        # 現行形式は status を持たない。二段階記録は廃止した。
        self.record(["aaa"])
        self.assertNotIn("status", self.read_state()["reviewed"]["aaa"])

    def test_二重記録しても増えない(self):
        self.record(["aaa"])
        self.record(["aaa"])
        self.assertEqual(len(self.read_state()["reviewed"]), 1)

    def test_0件でも落ちない(self):
        self.assertEqual(self.record([]), "0")

    def test_旧形式の実行台帳は書き戻しで捨てる(self):
        # lastRun はもう参照しない。残したままにすると、古い形式だけが増える。
        self.write_state({"version": 1, "reviewed": {}, "lastRun": {"S1#1": ["aaa"]}})
        self.record(["bbb"])
        self.assertNotIn("lastRun", self.read_state())

    def test_旧形式の検証待ちを記録すると除外対象になる(self):
        # 中断された旧記録も、提示し終えて --complete すればレビュー済みになる。
        self.write_state({"version": 1, "reviewed": {"aaa": {"status": "codex-done"}}})
        self.assertEqual(self.filter(["aaa"]), ["aaa"])
        self.record(["aaa"])
        self.assertEqual(self.filter(["aaa"]), [])


class TestPendingGate(StateTestBase):
    """record はレビューを通した SHA しか受け付けない。

    ここが緩いと、レビューしていないコミットを手入力で「レビュー済み」にでき、
    そのコミットは以後の対象から黙って外れる（レビュー漏れ）。
    """

    def test_レビューを通していないSHAは拒否する(self):
        result = run(["record", self.state, "--session", "S1", "aaa"])
        self.assertEqual(result.returncode, 1)
        self.assertIn("レビューを通していない", result.stderr)
        self.assertEqual(self.filter(["aaa"]), ["aaa"])

    def test_pendしたSHAは記録できる(self):
        self.pend(["aaa"])
        self.assertEqual(self.record(["aaa"], pend_first=False), "1")
        self.assertEqual(self.filter(["aaa"]), [])

    def test_pendだけでは除外されない(self):
        # 提示前に中断された場合にレビュー漏れにならないこと。
        self.pend(["aaa"])
        self.assertEqual(self.filter(["aaa"]), ["aaa"])

    def test_一部でも未レビューなら何も記録しない(self):
        self.pend(["aaa"])
        result = run(["record", self.state, "--session", "S1", "aaa", "bbb"])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(sorted(self.filter(["aaa", "bbb"])), ["aaa", "bbb"])

    def test_記録済みSHAの再指定は成功する(self):
        self.record(["aaa"])
        self.assertEqual(self.record(["aaa"], pend_first=False), "1")

    def test_記録するとpendingから消える(self):
        self.pend(["aaa"])
        self.record(["aaa"], pend_first=False)
        self.assertEqual(self.read_state()["pending"], {})

    def test_壊れたpendingは空として扱う(self):
        self.write_state({"version": 2, "reviewed": {}, "pending": "broken"})
        result = run(["record", self.state, "--session", "S1", "aaa"])
        self.assertEqual(result.returncode, 1)


class TestList(StateTestBase):
    def test_記録した行を出す(self):
        self.record(["aaa"], findings="2", blockers="1")
        result = run(["list", self.state])
        self.assertEqual(result.returncode, 0, result.stderr)
        row = result.stdout.strip().split("\t")
        self.assertEqual(row[0], "aaa")
        self.assertEqual(row[1], "レビュー済み")
        self.assertEqual(row[3], "2")
        self.assertEqual(row[4], "1")

    def test_旧形式の検証待ちは区別して出す(self):
        self.write_state({"version": 1, "reviewed": {"aaa": {"status": "codex-done"}}})
        result = run(["list", self.state])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("未レビュー(旧形式/不正)", result.stdout)

    def test_記録が無ければ空(self):
        result = run(["list", self.state])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "")


if __name__ == "__main__":
    unittest.main()
