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

"""Fail-closed tests for combining independently produced platform reports."""

import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock


def load_module():
    """Load the command-line module without altering import paths."""
    path = Path(__file__).with_name("merge-sonarqube-generic.py")
    spec = importlib.util.spec_from_file_location("containerization_coverage_merge", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


coverage = load_module()
GUEST = sorted(coverage.GUEST_FILES)
MAC = "Sources/Containerization/VsockListener.swift"
TRACKED = set(GUEST) | {MAC}
IDENTITY = {
    "schema": 1,
    "head": "a" * 40,
    "tree": "b" * 40,
    "package_resolved_sha256": "c" * 64,
}


class MergeTests(unittest.TestCase):
    """Coverage must be real, source-bound, and lossless across platforms."""

    def test_combines_hits_without_losing_uncovered_lines(self) -> None:
        """A line reached on either platform is covered; zero-hit lines survive."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            mac = root / "mac.xml"
            linux = root / "linux.xml"
            receipt = root / "identity.json"
            output = root / "merged.xml"
            coverage.write_xml({MAC: {1: False, 2: True}, GUEST[0]: {10: False}}, mac)
            coverage.write_xml({MAC: {1: True, 3: False}, GUEST[0]: {10: False}, GUEST[1]: {20: True}}, linux)
            with mock.patch.object(coverage, "repository_identity", return_value=(dict(IDENTITY), TRACKED)):
                coverage.stamp(linux, root, receipt)
                coverage.merge(mac, linux, receipt, root, output)
            self.assertEqual(
                coverage.read_report(output, TRACKED),
                {MAC: {1: True, 2: True, 3: False}, GUEST[0]: {10: False}, GUEST[1]: {20: True}},
            )

    def test_stamp_requires_both_linux_guest_files(self) -> None:
        """An ordinary macOS-shaped report cannot silently fill the Linux gap."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = root / "linux.xml"
            coverage.write_xml({MAC: {1: True}, GUEST[0]: {10: False}}, report)
            with mock.patch.object(coverage, "repository_identity", return_value=(dict(IDENTITY), TRACKED)):
                with self.assertRaisesRegex(ValueError, "missing guest line records"):
                    coverage.stamp(report, root, root / "identity.json")
            self.assertFalse((root / "identity.json").exists())

    def test_missing_and_untracked_reports_fail(self) -> None:
        """Missing evidence and source paths outside the analyzed tree are rejected."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaisesRegex(ValueError, "missing, linked, or empty"):
                coverage.read_report(root / "missing.xml", TRACKED)
            report = root / "untracked.xml"
            coverage.write_xml({"/tmp/Other.swift": {1: True}}, report)
            with self.assertRaisesRegex(ValueError, "not project-relative"):
                coverage.read_report(report, TRACKED)
            coverage.write_xml({"Sources/Other.swift": {1: True}}, report)
            with self.assertRaisesRegex(ValueError, "not tracked"):
                coverage.read_report(report, TRACKED)

    def test_duplicate_file_and_line_records_fail(self) -> None:
        """Ambiguous evidence cannot be counted twice or overwrite hits."""
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "duplicates.xml"
            report.write_text(
                '<coverage version="1"><file path="' + MAC + '"><lineToCover lineNumber="1" covered="true" />'
                '<lineToCover lineNumber="1" covered="false" /></file></coverage>',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "invalid or duplicate coverage line"):
                coverage.read_report(report, TRACKED)
            report.write_text(
                '<coverage version="1"><file path="' + MAC + '"><lineToCover lineNumber="1" covered="true" />'
                '</file><file path="' + MAC + '"><lineToCover lineNumber="2" covered="true" />'
                '</file></coverage>',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "duplicate coverage file"):
                coverage.read_report(report, TRACKED)

    def test_different_source_or_report_identity_fails(self) -> None:
        """A report from another commit, lock, or modified XML cannot cross the boundary."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            mac = root / "mac.xml"
            linux = root / "linux.xml"
            receipt = root / "identity.json"
            output = root / "merged.xml"
            coverage.write_xml({MAC: {1: False}}, mac)
            coverage.write_xml({GUEST[0]: {10: True}, GUEST[1]: {20: False}}, linux)
            with mock.patch.object(coverage, "repository_identity", return_value=(dict(IDENTITY), TRACKED)):
                coverage.stamp(linux, root, receipt)
            for key, replacement in (("head", "d" * 40), ("tree", "e" * 40), ("package_resolved_sha256", "f" * 64)):
                changed = dict(IDENTITY, **{key: replacement})
                with self.subTest(key=key), mock.patch.object(coverage, "repository_identity", return_value=(changed, TRACKED)):
                    with self.assertRaisesRegex(ValueError, "does not match"):
                        coverage.merge(mac, linux, receipt, root, output)
            coverage.write_xml({GUEST[0]: {10: False}, GUEST[1]: {20: False}}, linux)
            with mock.patch.object(coverage, "repository_identity", return_value=(dict(IDENTITY), TRACKED)):
                with self.assertRaisesRegex(ValueError, "does not match"):
                    coverage.merge(mac, linux, receipt, root, output)
            self.assertFalse(output.exists())

    def test_duplicate_identity_fields_fail(self) -> None:
        """Ambiguous metadata cannot select a favorable source identity."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            mac = root / "mac.xml"
            linux = root / "linux.xml"
            receipt = root / "identity.json"
            coverage.write_xml({MAC: {1: True}}, mac)
            coverage.write_xml({GUEST[0]: {10: True}, GUEST[1]: {20: False}}, linux)
            receipt.write_text('{"schema": 1, "head": "wrong", "head": "' + IDENTITY["head"] + '"}', encoding="utf-8")
            with mock.patch.object(coverage, "repository_identity", return_value=(dict(IDENTITY), TRACKED)):
                with self.assertRaisesRegex(ValueError, "duplicate Linux coverage identity field"):
                    coverage.merge(mac, linux, receipt, root, root / "merged.xml")


if __name__ == "__main__":
    unittest.main()
