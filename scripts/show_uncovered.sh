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
# Shows uncovered lines for files matching a pattern in the combined lcov report.
# Usage: scripts/show_uncovered.sh <pattern> [pattern2 ...]
# Example: scripts/show_uncovered.sh repl_runner toggle_commands
set -euo pipefail
cd "$(dirname "$0")/.."

LCOV="site/coverage/lcov.info"
if [[ ! -f "$LCOV" ]]; then
  echo "ERROR: $LCOV not found. Run make coverage first." >&2
  exit 1
fi

PATTERNS=("$@")
if [[ ${#PATTERNS[@]} -eq 0 ]]; then
  echo "Usage: $0 <pattern> [pattern2 ...]" >&2
  exit 1
fi

python3 - "$LCOV" "${PATTERNS[@]}" <<'PYEOF'
import sys

lcov_file = sys.argv[1]
patterns = sys.argv[2:]

lcov = open(lcov_file).read()
records = lcov.split('end_of_record')

for r in records:
    lines = r.strip().split('\n')
    sf = next((l for l in lines if l.startswith('SF:')), '')
    if any(p in sf for p in patterns):
        uncovered = [l for l in lines if l.startswith('DA:') and l.endswith(',0')]
        total = len([l for l in lines if l.startswith('DA:')])
        hit = total - len(uncovered)
        pct = (hit / total * 100) if total else 0
        print(f'\n{sf} ({pct:.1f}% {hit}/{total})')
        for u in uncovered:
            line_no = u.split(',')[0].replace('DA:', '')
            print(f'  line {line_no}: uncovered')
PYEOF
