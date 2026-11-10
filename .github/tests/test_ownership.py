"""Unsigned actual-source tests; no project build, 4D host, or release tools."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(os.environ.get("ARGUMENTS_OWNERSHIP_SOURCE_ROOT", ROOT)).resolve()


@unittest.skipUnless(sys.platform == "darwin", "requires Apple's native frameworks")
class OwnershipTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="arguments-ownership-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.binary = Path(cls.temp.name) / "ownership"
        command = [
            "clang++", "-std=c++11", "-x", "objective-c++", "-g", "-O1",
            "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
            "-Wno-deprecated-declarations", "-Wno-writable-strings",
            "-Wno-return-type-c-linkage", "-Wno-multichar",
            "-I", str(SOURCE), "-I", str(SOURCE / "4D Plugin API"),
            "-I", str(SOURCE / "4D Plugin API/Classes"),
            "-I", str(SOURCE / "support"),
            str(ROOT / ".github/tests/ownership.mm"),
            str(SOURCE / "4D Plugin API/4DPluginAPI.c"),
            str(SOURCE / "4DPlugin-arguments.cpp"),
            str(SOURCE / "support/4DPlugin-JSON.cpp"),
            *map(str, sorted((SOURCE / "4D Plugin API/Classes").glob("*.cpp"))),
            "-framework", "Cocoa", "-framework", "CoreGraphics",
            "-o", str(cls.binary),
        ]
        result = subprocess.run(command, capture_output=True, text=True, timeout=120)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)

    def exercise(self, case):
        for empties in ("allocated", "null"):
            with self.subTest(empties=empties):
                result = subprocess.run(
                    [str(self.binary), case, empties, "ASCII", "\u65e5\u672c",
                     "\U0001f600", ""],
                    env={**os.environ, "ASAN_OPTIONS": "detect_leaks=0",
                         "UBSAN_OPTIONS": "halt_on_error=1"},
                    capture_output=True, text=True, timeout=30,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_command_argument_ownership(self):
        self.exercise("command")

    def test_setter_empty_overwrite(self):
        self.exercise("setters")

    def test_getter_owned_results(self):
        self.exercise("getters")

    def test_failed_getter_outputs(self):
        self.exercise("failures")

    def test_reference_handoffs(self):
        self.exercise("handoffs")

    def test_array_transfers_and_borrowed_copies(self):
        self.exercise("arrays")

    def test_content_setters(self):
        self.exercise("content")


if __name__ == "__main__":
    unittest.main()
