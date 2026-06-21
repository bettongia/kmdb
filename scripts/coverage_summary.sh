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
# Runs make coverage and prints a per-file summary sorted by coverage % ascending.
# Usage: scripts/coverage_summary.sh
set -euo pipefail
cd "$(dirname "$0")/.."

echo "Running make coverage — this may take a few minutes..."
make coverage 2>&1

LCOV="site/coverage/lcov.info"
if [[ ! -f "$LCOV" ]]; then
  echo "ERROR: $LCOV not found after coverage run." >&2
  exit 1
fi

echo ""
echo "=== Per-file coverage summary (sorted by % ascending) ==="
echo ""

# Parse lcov.info to extract per-file stats.
# SF: lines set the current filename.
# LF: total instrumented lines; LH: lines hit.
awk '
  /^SF:/ {
    file = substr($0, 4)
    lf = 0
    lh = 0
  }
  /^LF:/ { lf = substr($0, 4) + 0 }
  /^LH:/ { lh = substr($0, 4) + 0 }
  /^end_of_record/ {
    if (lf > 0) {
      pct = (lh / lf) * 100
      printf "%.1f%%\t%d/%d\t%s\n", pct, lh, lf, file
    }
  }
' "$LCOV" | sort -t$'\t' -k1 -n

echo ""
echo "=== Overall totals ==="
awk '
  /^LF:/ { total_lf += substr($0, 4) + 0 }
  /^LH:/ { total_lh += substr($0, 4) + 0 }
  END {
    if (total_lf > 0) {
      pct = (total_lh / total_lf) * 100
      printf "Overall: %.1f%%  (%d / %d lines)\n", pct, total_lh, total_lf
    }
  }
' "$LCOV"
