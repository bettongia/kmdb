---
description: Review the codebase for headers, doc comments, complexity comments, and test coverage.
---

This workflow ensures the codebase meets quality standards for documentation and testing.

// turbo
1. Run the license check to identify files missing the license header.
   ```bash
   make license_check
   ```

2. For any files reported as missing headers, add the following template to the top of the file (adjusting the year as appropriate):
   ```dart
   // Copyright 2026 The Aurochs KMesh Authors
   //
   // Licensed under the Apache License, Version 2.0 (the "License");
   // you may not use this file except in compliance with the License.
   // You may obtain a copy of the License at
   //
   //      https://www.apache.org/licenses/LICENSE-2.0
   //
   // Unless required by applicable law or agreed to in writing, software
   // distributed under the License is distributed on an "AS IS" BASIS,
   // WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   // See the License for the specific language governing permissions and
   // limitations under the License.
   ```

3. Review each Dart file in `lib/` and `test/` for doc comments:
   - Ensure all public classes, functions, and variables have `///` doc comments.
   - If missing, add descriptive comments explaining the purpose and usage.

4. Identify complex logic sections (e.g., nested loops, intricate regex, complex state transitions):
   - Add inline comments `//` to describe *what* is happening in these sections.
   - Focus on the "why" if the "how" is not immediately obvious.

5. Verify test coverage:
   - For every file in `lib/src/`, ensure there is a corresponding test file in `test/src/`.
   - Run the tests to ensure everything is passing:
     ```bash
     dart test
     ```
   - If coverage is missing for a specific logic branch, add a new test case.

6. Final quality check:
   - Ensure all modifications follow the project's style guide and linting rules.
   - Run `dart analyze` to catch any regressions.
