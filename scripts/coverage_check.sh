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
# Runs make coverage and exits 0 if overall coverage >= 95%, exits 1 otherwise.
# Prints the current percentage clearly.
# Usage: scripts/coverage_check.sh
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET=95

echo "Running make coverage — this may take a few minutes..."
make coverage 2>&1

LCOV="site/coverage/lcov.info"
if [[ ! -f "$LCOV" ]]; then
  echo "ERROR: $LCOV not found after coverage run." >&2
  exit 1
fi

# Compute overall LH/LF from combined lcov.info.
read -r TOTAL_LH TOTAL_LF < <(awk '
  /^LF:/ { total_lf += substr($0, 4) + 0 }
  /^LH:/ { total_lh += substr($0, 4) + 0 }
  END { print total_lh, total_lf }
' "$LCOV")

if [[ "$TOTAL_LF" -eq 0 ]]; then
  echo "ERROR: No instrumented lines found in $LCOV." >&2
  exit 1
fi

# Use awk for floating-point percentage (bc not always available).
PCT=$(awk "BEGIN { printf \"%.1f\", ($TOTAL_LH / $TOTAL_LF) * 100 }")
PCT_INT=$(awk "BEGIN { printf \"%d\", int(($TOTAL_LH / $TOTAL_LF) * 100) }")

echo ""
echo "=== Coverage result ==="
echo "Overall: ${PCT}%  (${TOTAL_LH} / ${TOTAL_LF} lines)"
echo "Target:  ${TARGET}.0%"

if [[ "$PCT_INT" -ge "$TARGET" ]]; then
  echo ""
  echo "PASS: Coverage ${PCT}% >= ${TARGET}%"
  exit 0
else
  echo ""
  echo "FAIL: Coverage ${PCT}% < ${TARGET}%"
  MISSING=$(awk "BEGIN { printf \"%d\", int($TOTAL_LF * $TARGET / 100) - $TOTAL_LH + 1 }")
  echo "Need approximately ${MISSING} more covered lines to reach ${TARGET}%."
  exit 1
fi
