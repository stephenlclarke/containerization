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

"""Generate one LLVM coverage report from every SwiftPM test bundle."""

import argparse
import os
import subprocess
import sys
from pathlib import Path
from typing import Callable, Sequence


Runner = Callable[..., subprocess.CompletedProcess[bytes]]


def discover_test_executables(build_bin_dir: Path) -> list[Path]:
    """Return validated test executables for legacy or split SwiftPM bundles."""
    if not build_bin_dir.is_dir():
        raise ValueError(f"build products directory does not exist: {build_bin_dir}")

    bundles = sorted(build_bin_dir.glob("*.xctest"))
    if not bundles:
        raise ValueError(f"no SwiftPM test bundles found in {build_bin_dir}")

    executables: list[Path] = []
    for bundle in bundles:
        name = bundle.name.removesuffix(".xctest")
        candidates = (bundle / "Contents" / "MacOS" / name, bundle / name)
        matches = [candidate for candidate in candidates if candidate.exists()]
        if len(matches) != 1:
            raise ValueError(f"expected one executable for {bundle}, found {len(matches)}")
        executable = matches[0]
        if executable.is_symlink() or not executable.is_file() or not os.access(executable, os.X_OK):
            raise ValueError(f"test bundle executable is not a regular executable: {executable}")
        executables.append(executable.resolve())
    return executables


def llvm_cov_command(
    mode: str,
    compilation_dir: Path,
    profile: Path,
    executables: Sequence[Path],
    xcrun: str = "xcrun",
) -> list[str]:
    """Build an llvm-cov command that merges every supplied test executable."""
    if mode not in ("show", "lcov"):
        raise ValueError(f"unsupported report mode: {mode}")
    if not profile.is_file():
        raise ValueError(f"coverage profile does not exist: {profile}")
    if not executables:
        raise ValueError("at least one test executable is required")

    command = [xcrun, "llvm-cov", "export" if mode == "lcov" else "show"]
    if mode == "lcov":
        command.append("--format=lcov")
    command.extend(
        [
            f"--compilation-dir={compilation_dir}",
            f"--instr-profile={profile}",
            "--ignore-filename-regex=.build/",
            "--ignore-filename-regex=.pb.swift",
            "--ignore-filename-regex=.proto",
            "--ignore-filename-regex=.grpc.swift",
            str(executables[0]),
        ]
    )
    for executable in executables[1:]:
        command.extend(("--object", str(executable)))
    return command


def write_report(command: Sequence[str], output: Path, runner: Runner = subprocess.run) -> None:
    """Run llvm-cov and replace the report only after a successful export."""
    temporary = output.with_suffix(f"{output.suffix}.tmp")
    try:
        with temporary.open("wb") as stream:
            runner(command, check=True, stdout=stream)
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)


def parse_args(arguments: Sequence[str]) -> argparse.Namespace:
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("show", "lcov"))
    parser.add_argument("--build-bin-dir", required=True, type=Path)
    parser.add_argument("--profile", required=True, type=Path)
    parser.add_argument("--compilation-dir", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args(arguments)


def main(arguments: Sequence[str] | None = None) -> int:
    """Generate the requested report and return a shell-friendly status."""
    args = parse_args(sys.argv[1:] if arguments is None else arguments)
    try:
        executables = discover_test_executables(args.build_bin_dir.resolve())
        command = llvm_cov_command(args.mode, args.compilation_dir.resolve(), args.profile.resolve(), executables)
        write_report(command, args.output.resolve())
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        print(f"coverage report failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
