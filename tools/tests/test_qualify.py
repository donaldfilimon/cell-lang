#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[1] / "qualify.py"

FAKE_GATE = r'''#!/bin/sh
scenario=${FAKE_SCENARIO:-complete}
stage() { printf '\n== %s ==\n' "$1"; }

# These literal headings are the source-of-truth inventory parsed by qualify.py.
printf '\n== build ==\n'
if [ "$scenario" = early ]; then printf '  FAIL  injected build failure\n'; exit 1; fi
printf '  ok    build\n'
printf '\n== tests ==\n'
printf '  ok    tests\n  ....  All 12 tests passed.\n'
printf '\n== corpus ==\n'
printf '  ok    corpus\n'
printf '\n== backend agreement ==\n'
printf '  ok    agreement\n'
printf '\n== mlir lowering ==\n'
if [ "$scenario" = partial ]; then printf '  SKIP  injected missing mlir-opt\n'; else printf '  ok    lowering\n'; fi
printf '\n== execution ==\n'
printf '  ok    execution\n'
printf '\n== leaks (docs/OWNERSHIP.md R11 disclosed gaps) ==\n'
if [ "$scenario" = disclosed ]; then printf '  ok    leaks fixture -> 3 leaks (pinned, injected)\n'; else printf '  ok    leaks fixture -> 0 leaks (pinned, injected)\n'; fi
printf '\n== backend answers ==\n'
printf '  ok    answers\n'
printf '\n== sanitized execution (AddressSanitizer) ==\n'
printf '  ok    sanitized\n'
if [ "$scenario" != missing ]; then
printf '\n== declared signatures (C is the reference) ==\n'
  if [ "$scenario" = disclosed ]; then printf '  ok    signatures fixture: MLIR disagrees with C (DISCLOSED, injected)\n'; else printf '  ok    signatures\n'; fi
fi
if [ "$scenario" = drift ] || [ "$scenario" = dirtydrift ]; then printf 'drift\n' >> tracked.txt; fi
if [ "$scenario" = signal ]; then kill -TERM $$; fi
if [ "$scenario" = truncated ]; then exit 0; fi
printf '\n== verdict ==\n'
printf '  clean\n'
[ "$scenario" = nonzero ] && exit 7
exit 0
'''


class QualifyIntegrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="cell qualify ")
        self.root = Path(self.temp.name)
        (self.root / "tools").mkdir()
        shutil.copy2(SOURCE, self.root / "tools/qualify.py")
        (self.root / "tools/check.sh").write_text(FAKE_GATE)
        (self.root / "tools/check.sh").chmod(0o755)
        (self.root / "tracked.txt").write_text("stable\n")
        (self.root / ".gitignore").write_text(".cell-cache/\n")
        subprocess.run(["git", "init", "-q"], cwd=self.root, check=True)
        subprocess.run(["git", "config", "user.email", "test@example.invalid"], cwd=self.root, check=True)
        subprocess.run(["git", "config", "user.name", "Test"], cwd=self.root, check=True)
        subprocess.run(["git", "add", "."], cwd=self.root, check=True)
        subprocess.run(["git", "commit", "-qm", "fixture"], cwd=self.root, check=True)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_qualify(self, scenario: str = "complete", *options: str, env: dict[str, str] | None = None):
        report = self.root / "artifacts with spaces" / "report.json"
        command = [str(self.root / "tools/qualify.py"), "--report", str(report), *options]
        run_env = os.environ.copy()
        run_env["FAKE_SCENARIO"] = scenario
        if env:
            run_env.update(env)
        result = subprocess.run(command, cwd=self.root, text=True, capture_output=True, env=run_env)
        return result, json.loads(report.read_text())

    def test_complete_clean_report(self):
        result, report = self.run_qualify()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(report["verdict"], "qualified")
        self.assertEqual(report["gate"]["returncode"], 0)
        self.assertEqual(report["test_counts"], {"library": 12, "cli": None, "runtime": None})
        self.assertEqual(len(report["stages"]), 10)
        self.assertTrue(Path(report["artifacts"]["log"]).read_text().endswith("  clean\n"))

    def test_partial_and_strict_skip(self):
        ordinary, report = self.run_qualify("partial")
        self.assertEqual((ordinary.returncode, report["verdict"]), (0, "partial"))
        strict, report = self.run_qualify("partial", "--strict")
        self.assertEqual(strict.returncode, 1)
        self.assertIn("strict qualification forbids skipped checks", report["errors"])

    def test_disclosures_and_release_rejection(self):
        ordinary, report = self.run_qualify("disclosed")
        self.assertEqual((ordinary.returncode, report["verdict"]), (0, "disclosed"))
        self.assertEqual(report["disclosed_defects"]["pinned_leaks"][0]["count"], 3)
        release, report = self.run_qualify("disclosed", "--release")
        self.assertEqual(release.returncode, 1)
        self.assertIn("release qualification forbids disclosed defects", report["errors"])

    def test_clean_release(self):
        result, report = self.run_qualify("complete", "--release")
        self.assertEqual(result.returncode, 0)
        self.assertTrue(report["local_gate_ready"])
        self.assertEqual(report["qualification_scope"], "local_gate")
        self.assertFalse(report["release_ready"])
        self.assertIn("three target platforms", report["release_readiness_reason"])

    def test_nonzero_and_early_build_failure(self):
        result, report = self.run_qualify("nonzero")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(report["gate"]["returncode"], 7)
        result, report = self.run_qualify("early")
        self.assertEqual(result.returncode, 1)
        self.assertIn("build", [stage["name"] for stage in report["stages"] if stage["ran"]])
        self.assertEqual(report["test_counts"]["library"], None)

    def test_source_drift_and_dirty_release(self):
        result, report = self.run_qualify("drift")
        self.assertEqual(result.returncode, 1)
        self.assertTrue(report["source"]["drifted"])
        subprocess.run(["git", "checkout", "--", "tracked.txt"], cwd=self.root, check=True)
        (self.root / "untracked.txt").write_text("dirty\n")
        result, report = self.run_qualify("complete", "--release")
        self.assertEqual(result.returncode, 1)
        self.assertIn("release qualification requires clean input", report["errors"])

    def test_content_change_to_already_dirty_path_is_drift(self):
        (self.root / "tracked.txt").write_text("already dirty\n")
        result, report = self.run_qualify("dirtydrift")
        self.assertEqual(result.returncode, 1)
        self.assertTrue(report["source"]["before"]["dirty"])
        self.assertTrue(report["source"]["drifted"])

    def test_signal_and_missing_stage(self):
        result, report = self.run_qualify("signal")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(report["gate"]["returncode"], -15)
        declared = next(stage for stage in report["stages"] if stage["name"].startswith("declared signatures"))
        self.assertEqual(declared["outcome"], "incomplete")
        result, report = self.run_qualify("missing")
        self.assertEqual(result.returncode, 1)
        self.assertIn("declared signatures (C is the reference)", report["missing_required_stages"])

    def test_exit_zero_without_clean_verdict_fails(self):
        result, report = self.run_qualify("truncated")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(report["gate"]["returncode"], 0)
        self.assertIn("gate output ended without a clean verdict", report["errors"])
        declared = next(stage for stage in report["stages"] if stage["name"].startswith("declared signatures"))
        self.assertEqual(declared["outcome"], "incomplete")

    def test_preexisting_tracked_deletion_is_measurable(self):
        (self.root / "tracked.txt").unlink()
        result, report = self.run_qualify("complete")
        self.assertEqual(result.returncode, 0)
        self.assertTrue(report["source"]["before"]["valid"])
        self.assertTrue(report["source"]["before"]["dirty"])
        self.assertFalse(report["source"]["drifted"])

    def test_preexisting_tracked_rename_is_measurable(self):
        subprocess.run(["git", "mv", "tracked.txt", "renamed tracked.txt"], cwd=self.root, check=True)
        result, report = self.run_qualify("complete")
        self.assertEqual(result.returncode, 0)
        self.assertTrue(report["source"]["before"]["valid"])
        self.assertTrue(report["source"]["before"]["dirty"])
        self.assertFalse(report["source"]["drifted"])

    def test_preexisting_staged_copy_is_measurable(self):
        subprocess.run(["git", "config", "status.renames", "copies"], cwd=self.root, check=True)
        shutil.copy2(self.root / "tracked.txt", self.root / "copied tracked.txt")
        subprocess.run(["git", "add", "copied tracked.txt"], cwd=self.root, check=True)
        result, report = self.run_qualify("complete")
        self.assertEqual(result.returncode, 0)
        self.assertTrue(report["source"]["before"]["valid"])
        self.assertTrue(report["source"]["before"]["dirty"])
        self.assertFalse(report["source"]["drifted"])

    def test_rejects_tracked_and_colliding_artifact_paths(self):
        qualify = str(self.root / "tools/qualify.py")
        tracked_before = (self.root / "tracked.txt").read_text()
        tracked_temporary = self.root / "reserved.json.tmp"
        tracked_temporary.write_text("must survive\n")
        subprocess.run(["git", "add", "reserved.json.tmp"], cwd=self.root, check=True)
        cases = [
            ["--report", str(self.root / "tracked.txt")],
            ["--log", str(self.root / "tracked.txt")],
            ["--report", str(self.root / "reserved.json")],
            ["--report", str(self.root / "tracked"), "--log", str(self.root / "tracked.tmp")],
            ["--report", str(self.root / "same"), "--log", str(self.root / "same")],
        ]
        alias = self.root / "tracked alias"
        alias.symlink_to(self.root / "tracked.txt")
        cases.append(["--report", str(alias)])
        for options in cases:
            with self.subTest(options=options):
                result = subprocess.run([qualify, *options], cwd=self.root, text=True, capture_output=True)
                self.assertEqual(result.returncode, 2)
                self.assertIn("error:", result.stderr)
                self.assertEqual((self.root / "tracked.txt").read_text(), tracked_before)
                self.assertEqual(tracked_temporary.read_text(), "must survive\n")

    def test_rejects_artifact_hardlinks_to_tracked_source(self):
        qualify = str(self.root / "tools/qualify.py")
        tracked = self.root / "tracked.txt"
        original = tracked.read_text()
        hard_log = self.root / "hard log"
        os.link(tracked, hard_log)
        result = subprocess.run(
            [qualify, "--report", str(self.root / "safe.json"), "--log", str(hard_log)],
            cwd=self.root, text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 2)
        self.assertEqual(tracked.read_text(), original)
        hard_log.unlink()

        hard_temporary = self.root / "safe.json.tmp"
        os.link(tracked, hard_temporary)
        result = subprocess.run(
            [qualify, "--report", str(self.root / "safe.json")],
            cwd=self.root, text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 2)
        self.assertEqual(tracked.read_text(), original)

    def test_rejects_pairwise_artifact_hardlink_aliases(self):
        qualify = str(self.root / "tools/qualify.py")
        report = self.root / "report.json"
        report.write_text("artifact\n")
        log = self.root / "gate.log"
        os.link(report, log)
        result = subprocess.run(
            [qualify, "--report", str(report), "--log", str(log)],
            cwd=self.root, text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 2)
        self.assertEqual(report.read_text(), "artifact\n")

    def test_rejects_outside_artifact_hardlinks(self):
        qualify = str(self.root / "tools/qualify.py")
        tracked = self.root / "tracked.txt"
        original = tracked.read_bytes()
        with tempfile.TemporaryDirectory(prefix="cell outside artifacts ") as directory:
            outside = Path(directory)
            for role in ("log", "temporary", "pairwise"):
                with self.subTest(role=role):
                    report = outside / (role + ".json")
                    log = outside / (role + ".log")
                    if role == "log":
                        os.link(tracked, log)
                    elif role == "temporary":
                        os.link(tracked, report.with_name(report.name + ".tmp"))
                    else:
                        report.write_text("preserved artifact")
                        os.link(report, log)
                    result = subprocess.run(
                        [qualify, "--report", str(report), "--log", str(log)],
                        cwd=self.root, text=True, capture_output=True,
                    )
                    self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                    self.assertIn("hardlink", result.stderr)
                    self.assertEqual(tracked.read_bytes(), original)
                    if role == "pairwise":
                        self.assertEqual(report.read_text(), "preserved artifact")

    def test_missing_tool_versions_are_null(self):
        absent = str(self.root / "does not exist")
        result, report = self.run_qualify("complete", env={"ZIG": absent, "CC": absent, "LLVM_BIN": absent})
        self.assertEqual(result.returncode, 0)
        self.assertIsNone(report["tools"]["zig"])
        self.assertIsNone(report["tools"]["clang"])
        self.assertIsNone(report["tools"]["llvm"])

    def test_default_artifacts_are_ignored(self):
        result = subprocess.run(
            [str(self.root / "tools/qualify.py")], cwd=self.root, text=True, capture_output=True,
            env={**os.environ, "FAKE_SCENARIO": "complete"},
        )
        self.assertEqual(result.returncode, 0)
        self.assertTrue((self.root / ".cell-cache/qualification/report.json").is_file())
        status = subprocess.run(["git", "status", "--porcelain"], cwd=self.root, text=True, capture_output=True, check=True)
        self.assertEqual(status.stdout, "")

    def test_launch_failure_still_writes_report(self):
        (self.root / "tools/check.sh").chmod(0o644)
        result, report = self.run_qualify("complete")
        self.assertEqual(result.returncode, 1)
        self.assertIsNone(report["gate"]["returncode"])
        self.assertIsNotNone(report["gate"]["launch_error"])


if __name__ == "__main__":
    unittest.main()
