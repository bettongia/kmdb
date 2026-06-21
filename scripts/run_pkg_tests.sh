#!/usr/bin/env bash
# Copyright 2026 The Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Runs dart test inside a given package directory, ensuring native-asset build
# hooks fire correctly (must be invoked from inside the package dir).
# Usage: scripts/run_pkg_tests.sh <package>
# Example: scripts/run_pkg_tests.sh kmdb_cli
set -euo pipefail
cd "$(dirname "$0")/.."

PACKAGE="${1:-}"
if [[ -z "$PACKAGE" ]]; then
  echo "Usage: $0 <package>" >&2
  echo "Example: $0 kmdb" >&2
  exit 1
fi

PKG_DIR="packages/$PACKAGE"
if [[ ! -d "$PKG_DIR" ]]; then
  echo "ERROR: package directory '$PKG_DIR' does not exist." >&2
  exit 1
fi

echo "Running dart test in $PKG_DIR ..."
cd "$PKG_DIR"
dart test "$@"
