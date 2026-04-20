---
name: JSONPath subset field path implementation
description: Key patterns and decisions from implementing the JSONPath subset for field path selectors (plan_jsonpath_subset.md)
type: project
---

## Key architectural decisions

**`normalisePath()` is public:** `FieldPath._normalise()` is private but also exposed as `FieldPath.normalisePath()` so `IndexDefinition` and `projectDocument()` can use it without importing internal paths. This avoids needing to add the src path import to consumers.

**`FieldPath` and `missing` exported from `kmdb.dart`:** The original code did NOT export these. The CLI `scan_command.dart` was using an `implementation_imports` lint violation (`package:kmdb/src/query/filter/field_path.dart`). Fixed by adding `export 'src/query/filter/field_path.dart' show FieldPath, missing;` to `kmdb.dart`. Any future consumers of FieldPath should use the public API.

**`projectDocument()` is a top-level function in scan_command.dart (not a method):** Shared between `ScanCommand` and `GetCommand`. It's top-level (not private) so `GetCommand` can import it from `scan_command.dart` via `import 'scan_command.dart'`. This pattern avoids creating a separate utility file for a small shared function.

**Re-nesting uses normalised path:** When `--select="$.address.city"` is used, the output key structure must be `{"address": {"city": "..."}}` not `{"$": {"address": {"city": "..."}}}`. The fix was to call `FieldPath.normalisePath(field)` to get the canonical path BEFORE splitting on `.` for re-nesting. This was a subtle bug in the initial implementation.

**Flat key for all bracket selections (including `[*]` after normalisation):** After normalisation, `tags[*]` becomes `tags[]`. The flat key in output is the normalised form: `{"tags[]": [...]}` not `{"tags[*]": [...]}`. The `normField.contains('[')` check works on the normalised path.

## Test patterns

- `field_path_test.dart`: Groups by feature (root sigil, wildcard, negative indices, regression). Tests include `normalisePath()` directly as a public API test.
- CLI tests in `commands_test.dart`: Use inline `_putDoc()` within test bodies rather than shared setUp() because the nested-path tests need documents not in the standard fixture. Create separate collection names (e.g. `nested_items`, `arr_items`) to avoid interference with the shared `items` fixture.

## Why: The `make checks` target

`make checks` requires `melos` which may not be available in the sandbox. Run individual checks instead:
- `dart analyze packages/kmdb packages/kmdb_cli`
- `dart format --output=none packages/`
- Tests separately for each package

## Pre-existing test failures

`packages/kmdb/test/encoding/value_codec_test.dart` has Zstd-related failures when the native library is not compiled for the current platform. These are environment-specific, not regressions. The `builders/` directory only has `linux/` binaries so the tests fail on macOS in the sandbox. The tests pass on the main `kmdb` branch when run outside the sandbox.
