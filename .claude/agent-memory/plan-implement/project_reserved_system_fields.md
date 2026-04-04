---
name: Reserved system fields implementation patterns
description: Key patterns from implementing the _ prefix convention and _id document key
type: project
---

Implemented plan_reserved_system_fields (PR #5, branch 20260404_plan_reserved_system_fields).

**Why:** The `id` field was a common collision with user models; `_id` reserves a safe namespace for KMDB system fields.

**Key implementation patterns:**

1. Validation happens in `KmdbCollection._validateNoReservedKeys()` — a static method called from `_writeDocument()` before any I/O. This ensures no partial writes on reserved field errors.

2. `_id` injection happens in two places:
   - `KmdbCollection.get()` — injects into decoded map before `codec.decode()`
   - `KmdbQuery._execute()` — injects into each doc map during the scan loop (before filters run, so filters on `_id` work too)

3. `IndexDefinition` constructor throws `ReservedIndexPathException` eagerly — this makes validation happen at `KmdbDatabase.open()` time before any writes.

4. The CLI operates at the raw `KvStore` layer and stores `_id` in the value bytes (unlike `KmdbCollection` which strips it). This is intentional — the CLI is a direct store manipulator.

5. `_putDoc` test helper uses `_id` as the key field. All test documents at the raw store level should use `_id` for the key field.

6. The `cli_runner_test.dart` tests were already failing pre-change (7 tests fail because `bin/kmdb.dart` is not found when running from workspace root). Do not count these as regressions.

**How to apply:** When adding future system fields (e.g. `_rev`, `_ts`), follow same injection pattern in `get()` and `_execute()`. Never store them in value bytes.
