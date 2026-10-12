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

"""Bind Linux coverage to one source tree and combine real platform line hits."""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import subprocess
import sys
import xml.etree.ElementTree as ET


GUEST_FILES = frozenset({
    "vminitd/Sources/VminitdCore/ManagedContainer.swift",
    "vminitd/Sources/VminitdCore/RuncProcess.swift",
})


def sha256(path: Path) -> str:
    """Hash an evidence file without trusting its name."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git_output(repository: Path, *args: str) -> bytes:
    """Read a Git identity from the exact checkout used for the report."""
    return subprocess.check_output(["git", "-C", str(repository), *args])


def repository_identity(repository: Path) -> tuple[dict[str, object], set[str]]:
    """Reject tracked source drift and identify the complete committed tree."""
    repository = repository.resolve()
    if git_output(repository, "status", "--porcelain", "--untracked-files=no").strip():
        raise ValueError("tracked source changed while producing coverage")
    lock = repository / "Package.resolved"
    if not lock.is_file() or lock.is_symlink():
        raise ValueError("Package.resolved is missing or linked")
    identity: dict[str, object] = {
        "schema": 1,
        "head": git_output(repository, "rev-parse", "HEAD").decode().strip(),
        "tree": git_output(repository, "rev-parse", "HEAD^{tree}").decode().strip(),
        "package_resolved_sha256": sha256(lock),
    }
    tracked = set(git_output(repository, "ls-files", "-z").decode().rstrip("\0").split("\0"))
    return identity, tracked


def source_path(value: str, tracked: set[str]) -> str:
    """Accept only canonical project-relative paths from the committed tree."""
    path = PurePosixPath(value)
    if (
        not value
        or "\\" in value
        or path.is_absolute()
        or path.as_posix() != value
        or any(part in (".", "..") for part in value.split("/"))
    ):
        raise ValueError(f"coverage source path is not project-relative: {value!r}")
    if value not in tracked:
        raise ValueError(f"coverage source path is not tracked: {value}")
    return value


def read_report(report: Path, tracked: set[str]) -> dict[str, dict[int, bool]]:
    """Read genuine Sonar generic line records, rejecting ambiguous inputs."""
    if report.is_symlink() or not report.is_file() or report.stat().st_size == 0:
        raise ValueError(f"coverage report missing, linked, or empty: {report}")
    root = ET.parse(report).getroot()
    if root.tag != "coverage" or root.get("version") != "1":
        raise ValueError(f"unsupported coverage report: {report}")
    files: dict[str, dict[int, bool]] = {}
    for element in root:
        if element.tag != "file":
            raise ValueError(f"unexpected coverage element in {report}")
        name = source_path(element.get("path", ""), tracked)
        if name in files:
            raise ValueError(f"duplicate coverage file: {name}")
        lines: dict[int, bool] = {}
        for line in element:
            if line.tag != "lineToCover":
                raise ValueError(f"unexpected coverage line element: {name}")
            try:
                number = int(line.get("lineNumber", ""))
            except ValueError as error:
                raise ValueError(f"invalid coverage line number: {name}") from error
            covered = line.get("covered")
            if number <= 0 or covered not in ("true", "false") or number in lines:
                raise ValueError(f"invalid or duplicate coverage line: {name}:{number}")
            lines[number] = covered == "true"
        files[name] = lines
    if not any(files.values()):
        raise ValueError(f"coverage report has no line records: {report}")
    return files


def require_guest_coverage(files: dict[str, dict[int, bool]]) -> None:
    """A macOS-only or unrelated Linux report cannot satisfy guest coverage."""
    missing = sorted(name for name in GUEST_FILES if not files.get(name))
    if missing:
        raise ValueError("Linux coverage is missing guest line records: " + ", ".join(missing))


def write_json(value: dict[str, object], output: Path) -> None:
    """Replace an identity receipt only after its complete serialization."""
    temporary = output.with_name(output.name + ".tmp")
    try:
        temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)


def unique_json_pairs(pairs: list[tuple[str, object]]) -> dict[str, object]:
    """Reject conflicting or repeated receipt fields before identity comparison."""
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate Linux coverage identity field: {key}")
        result[key] = value
    return result


def stamp(report: Path, repository: Path, output: Path) -> None:
    """Create a Linux coverage identity for a clean exact source checkout."""
    identity, tracked = repository_identity(repository)
    require_guest_coverage(read_report(report, tracked))
    identity["report_sha256"] = sha256(report)
    write_json(identity, output)


def combine(mac: dict[str, dict[int, bool]], linux: dict[str, dict[int, bool]]) -> dict[str, dict[int, bool]]:
    """Count a source line as hit when an instrumented platform hit it."""
    merged = {name: dict(lines) for name, lines in mac.items()}
    for name, lines in linux.items():
        destination = merged.setdefault(name, {})
        for number, covered in lines.items():
            destination[number] = destination.get(number, False) or covered
    return merged


def write_xml(files: dict[str, dict[int, bool]], output: Path) -> None:
    """Atomically publish the combined generic report."""
    root = ET.Element("coverage", version="1")
    for name in sorted(files):
        file_element = ET.SubElement(root, "file", path=name)
        for number in sorted(files[name]):
            ET.SubElement(
                file_element,
                "lineToCover",
                lineNumber=str(number),
                covered=str(files[name][number]).lower(),
            )
    tree = ET.ElementTree(root)
    ET.indent(tree, space="  ")
    temporary = output.with_name(output.name + ".tmp")
    try:
        tree.write(temporary, encoding="utf-8", xml_declaration=True)
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)


def merge(mac_report: Path, linux_report: Path, receipt: Path, repository: Path, output: Path) -> None:
    """Require identical source identity before combining both platform reports."""
    identity, tracked = repository_identity(repository)
    if receipt.is_symlink() or not receipt.is_file():
        raise ValueError("Linux coverage identity is missing or linked")
    supplied = json.loads(receipt.read_text(encoding="utf-8"), object_pairs_hook=unique_json_pairs)
    expected = dict(identity, report_sha256=sha256(linux_report))
    if not isinstance(supplied, dict) or type(supplied.get("schema")) is not int or supplied != expected:
        raise ValueError("Linux coverage identity does not match this source tree, lock, or report")
    mac = read_report(mac_report, tracked)
    linux = read_report(linux_report, tracked)
    require_guest_coverage(linux)
    write_xml(combine(mac, linux), output)


def main(arguments: list[str] | None = None) -> int:
    """Stamp or merge one source-bound coverage report."""
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    stamp_parser = subparsers.add_parser("stamp")
    stamp_parser.add_argument("--repository", type=Path, required=True)
    stamp_parser.add_argument("--report", type=Path, required=True)
    stamp_parser.add_argument("--output", type=Path, required=True)
    merge_parser = subparsers.add_parser("merge")
    merge_parser.add_argument("--repository", type=Path, required=True)
    merge_parser.add_argument("--mac", type=Path, required=True)
    merge_parser.add_argument("--linux", type=Path, required=True)
    merge_parser.add_argument("--identity", type=Path, required=True)
    merge_parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(arguments)
    try:
        if args.command == "stamp":
            stamp(args.report, args.repository, args.output)
        else:
            merge(args.mac, args.linux, args.identity, args.repository, args.output)
    except (OSError, ValueError, ET.ParseError, subprocess.CalledProcessError) as error:
        print(f"coverage merge failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
