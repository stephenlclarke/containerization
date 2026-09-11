#!/usr/bin/env bash
# Copyright © 2026 Apple Inc. and the Containerization project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -Eeuo pipefail

readonly CANONICAL_NIO_SSL_URL="https://github.com/apple/swift-nio-ssl.git"

# Reject every literal swift-nio-ssl repository URL or path except the canonical
# URL. Matching the complete quoted value also covers SwiftPM's relative and
# absolute local-source-control forms.
main() {
  local evaluated git_matches git_status manifest noncanonical="" match
  local package_directory url
  set +e
  git_matches="$(git grep -inoE \
    '"[^"]*/swift-nio-ssl(\.git)?/?"' -- \
    '*Package*.swift' '*Package.resolved')"
  git_status=$?
  set -e
  if ((git_status > 1)); then
    printf 'could not inspect tracked SwiftPM manifests and lockfiles\n' >&2
    return "${git_status}"
  fi

  # Evaluate every tracked package manifest as well as scanning its source.
  # This catches valid Swift expressions which compose a repository URL from
  # fragments in the root package, vminitd, or either example package.
  while IFS= read -r -d '' manifest; do
    package_directory="${manifest%/Package.swift}"
    if [[ "${package_directory}" == "${manifest}" ]]; then
      package_directory="."
    fi
    evaluated="$(swift package --package-path "${package_directory}" dump-package)"
    while IFS= read -r match; do
      [[ -n "${match}" ]] || continue
      git_matches+=$'\n'"${manifest}:${match}"
    done < <(
      grep -inoE '"[^"]*/swift-nio-ssl(\.git)?/?"' <<<"${evaluated}" || true
    )
  done < <(git ls-files -z '*Package.swift')

  shopt -s nocasematch
  while IFS= read -r match; do
    [[ -n "${match}" ]] || continue
    url="${match#*:*:}"
    url="${url#\"}"
    url="${url%\"}"
    if [[ "${url}" != "${CANONICAL_NIO_SSL_URL}" ]]; then
      noncanonical+="${match}"$'\n'
    fi
  done <<<"${git_matches}"
  shopt -u nocasematch
  if [[ -n "${noncanonical}" ]]; then
    printf '%s' "${noncanonical}" >&2
    printf 'SwiftPM manifests and lockfiles must use the canonical swift-nio-ssl URL\n' >&2
    return 1
  fi
}

main "$@"
