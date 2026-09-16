#!/usr/bin/env python3
##===----------------------------------------------------------------------===##
## Copyright 2026 Containerization project authors.
##
## Licensed under the Apache License, Version 2.0 (the "License");
## you may not use this file except in compliance with the License.
## You may obtain a copy of the License at
##
## https://www.apache.org/licenses/LICENSE-2.0
##
## Unless required by applicable law or agreed to in writing, software
## distributed under the License is distributed on an "AS IS" BASIS,
## WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
## See the License for the specific language governing permissions and
## limitations under the License.
##===----------------------------------------------------------------------===##

"""Tests for the SwiftPM LLVM coverage report helper."""

import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


def load_module():
    """Load the coverage helper from its CLI-oriented location."""
    path = Path(__file__).with_name("llvm_cov_report.py")
    spec = importlib.util.spec_from_file_location("containerization_llvm_cov", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


coverage = load_module()


def make_bundle(root: Path, name: str, darwin: bool = True) -> Path:
    """Create a minimal executable SwiftPM test bundle fixture."""
    bundle = root / f"{name}.xctest"
    executable = bundle / "Contents" / "MacOS" / name if darwin else bundle / name
    executable.parent.mkdir(parents=True)
    executable.write_bytes(b"fixture")
    executable.chmod(0o755)
    return executable.resolve()


class DiscoveryTests(unittest.TestCase):
    """Validate old and new SwiftPM bundle discovery."""

    def test_discovers_split_bundles_in_stable_order(self) -> None:
        """Every independently emitted test target is passed to llvm-cov."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            second = make_bundle(root, "ZetaTests")
            first = make_bundle(root, "AlphaTests")
            self.assertEqual(coverage.discover_test_executables(root), [first, second])

    def test_discovers_legacy_non_darwin_aggregate_bundle(self) -> None:
        """The helper retains the historical single-bundle layout."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = make_bundle(root, "containerizationPackageTests", darwin=False)
            self.assertEqual(coverage.discover_test_executables(root), [executable])

    def test_rejects_empty_build_products(self) -> None:
        """Missing test instrumentation fails before llvm-cov runs."""
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, "no SwiftPM test bundles"):
                coverage.discover_test_executables(Path(directory))

    def test_rejects_bundle_without_expected_executable(self) -> None:
        """A malformed bundle cannot silently reduce coverage scope."""
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "BrokenTests.xctest"
            bundle.mkdir()
            with self.assertRaisesRegex(ValueError, "expected one executable"):
                coverage.discover_test_executables(Path(directory))

    def test_rejects_symlinked_executable(self) -> None:
        """Coverage objects must be regular build outputs."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "target"
            target.write_bytes(b"fixture")
            target.chmod(0o755)
            executable = root / "LinkedTests.xctest" / "Contents" / "MacOS" / "LinkedTests"
            executable.parent.mkdir(parents=True)
            executable.symlink_to(target)
            with self.assertRaisesRegex(ValueError, "not a regular executable"):
                coverage.discover_test_executables(root)


class CommandTests(unittest.TestCase):
    """Validate multi-object command construction and atomic output."""

    def test_lcov_command_includes_every_object(self) -> None:
        """The first object is positional and every remaining object is explicit."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile = root / "default.profdata"
            profile.write_bytes(b"profile")
            objects = [root / "OneTests", root / "TwoTests"]
            command = coverage.llvm_cov_command("lcov", root, profile, objects)
            self.assertEqual(command[:4], ["xcrun", "llvm-cov", "export", "--format=lcov"])
            self.assertEqual(command[-3:], [str(objects[0]), "--object", str(objects[1])])

    def test_write_report_replaces_output_after_success(self) -> None:
        """A complete report atomically replaces the previous file."""
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "coverage.lcov"
            output.write_text("old", encoding="utf-8")

            def runner(_command, check, stdout):
                self.assertTrue(check)
                stdout.write(b"new")
                return subprocess.CompletedProcess([], 0)

            coverage.write_report(["llvm-cov"], output, runner=runner)
            self.assertEqual(output.read_text(encoding="utf-8"), "new")

    def test_write_report_preserves_output_after_failure(self) -> None:
        """A failed export cannot leave partial evidence in place."""
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "coverage.lcov"
            output.write_text("old", encoding="utf-8")
            runner = mock.Mock(side_effect=subprocess.CalledProcessError(1, ["llvm-cov"]))
            with self.assertRaises(subprocess.CalledProcessError):
                coverage.write_report(["llvm-cov"], output, runner=runner)
            self.assertEqual(output.read_text(encoding="utf-8"), "old")
            self.assertFalse(output.with_suffix(".lcov.tmp").exists())


if __name__ == "__main__":
    unittest.main()
