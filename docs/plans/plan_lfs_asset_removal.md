# LFS Asset Removal — Replace bundled BGE model with download-on-demand

**Status**: Implementing

**PR link**: _(pending)_

**Roadmap**: [v0.05 — LFS asset removal](../roadmap/0_05.md#lfs-asset-removal)

## Problem statement

`packages/kmdb_inferencing/assets/models/bge-small-en/bge_small.onnx` is tracked
by Git LFS. It is a **~133 MB** binary (133,041,945 bytes on disk) that every
`git clone` must fetch from LFS storage, even for developers who never run
semantic search. LFS itself is an operational dependency: LFS bandwidth counts
against GitHub's metered quota, and a missing LFS credential silently produces a
text pointer stub where a binary file is expected, causing opaque runtime
failures.

The removal is now unblocked: `betto_onnxrt` Stage A established the
`ModelDownloader` + `ModelCatalog` download-on-demand path, proven in CI.
`OnnxEmbeddingModel.load(spec:, cacheDir:)` already supports this path. The
LFS bundle is a redundant fallback that should be retired.

**Scope:** Remove `bge_small.onnx` from Git LFS, from the working tree, and from
Git history (full blob purge — see Phase 3). The non-ONNX files in
`assets/models/bge-small-en/` (`vocab.txt`, `tokenizer.json`,
`tokenizer_config.json`, `special_tokens_map.json`, `config.json`) are
plain-git, small, and **must remain** — `BertTokenizer` loads `vocab.txt` from
this directory and `bert_tokenizer_test.dart` skips all tokenizer tests when it
is absent.

Secondary goal: remove the now-dead LFS fallback (`_defaultModelPath()`) from
`OnnxEmbeddingModel.load()` so the download-on-demand path
(`spec + cacheDir`) or an explicit `modelPath` is the only supported mechanism,
and fix every caller and doc example that relied on the no-arg fallback.

> **No stub fixture.** An earlier draft proposed a BGE-shaped stub `.onnx`
> fixture and a `generate_bge_fixture.dart` generator to add a "CI-safe"
> inference test. That is **dropped** (decision 2026-06-10). Two reasons:
> (1) Any test that drives the ORT runtime auto-skips under JIT/CI and only runs
> under AOT at release time, so it would add **zero** CI coverage — it is not
> "CI-safe". (2) The embed pipeline's only non-trivial pure logic —
> `meanPool` and `l2Normalize` in `lib/src/math_utils.dart` — is **already
> comprehensively unit-tested** in `test/math_utils_test.dart` (averaging,
> padding exclusion, zero-vector degenerate case, unit-norm, negative
> components, single-element). Those tests run in CI under JIT with no ORT
> dependency and already give the coverage the stub was meant to provide. No
> new stub, no generator, no `test/fixtures/` directory, no new `vocabPath`
> parameter on `load()`. See Phase 2 for the (small) gap, if any, to close.

## Open questions

_All resolved 2026-06-10. Decisions recorded inline below and in the Review
section._

- [x] **Q1 / Q3 / Q5 / Q6 — Stub fixture.** Dropped entirely. No stub `.onnx`,
  no generator, no `test/fixtures/`, no fixture dimension question, no
  "CI-safe inference test" (it would always skip in CI). The embed pipeline's
  pure logic is already covered by `test/math_utils_test.dart`. This resolves
  the fixture dimension (Q1), the protobuf-encoding design task (Q3), the
  misleading "CI-safe" framing (Q5), and the roadmap dim-384 conflict (Q6) in
  one stroke. The roadmap's stub reference (`0_05.md` lines 96–101) is now
  moot and must be updated to the unit-test approach (roadmap edits are the
  kmdb-architect's job — see Phase 5).
- [x] **Q2 — Remove `_defaultModelPath()`.** Removed entirely. Callers must
  supply `modelPath` or `cacheDir` (+ `spec`). See Phase 4.
- [x] **Q4 — Post-removal `load()` no-arg contract + broken callers.** A no-arg
  `load()` throws `ArgumentError` (see Phase 4 for the exact message). All four
  broken callers are enumerated and fixed in Phase 4 / Phase 5.
- [x] **Q7 — Git history rewrite.** In scope. Use `git filter-repo` to purge
  the blob from history so clones no longer pay the LFS cost. Coordination
  (force-push to `main`, team re-clone) documented in Phase 3.

## Investigation

### What is actually in LFS

`.gitattributes` at the repo root declares:

```
*.onnx filter=lfs diff=lfs merge=lfs -text
```

Only `bge_small.onnx` matches this pattern in `kmdb_inferencing`. No other
`*.onnx` files are present in the repository. After removal the `*.onnx` rule
can be dropped from `.gitattributes` entirely.

The remaining files in `assets/models/bge-small-en/`:

| File | Size | LFS? | Keep? |
|---|---|---|---|
| `bge_small.onnx` | ~133 MB | ✅ LFS | ❌ Remove |
| `vocab.txt` | ~230 KB | plain git | ✅ Keep |
| `tokenizer.json` | ~700 KB | plain git | ✅ Keep |
| `tokenizer_config.json` | ~1 KB | plain git | ✅ Keep |
| `special_tokens_map.json` | ~1 KB | plain git | ✅ Keep |
| `config.json` | ~1 KB | plain git | ✅ Keep |

### Embed-pipeline test coverage already exists

The only non-trivial pure logic in the embed path is `meanPool` and
`l2Normalize` (`lib/src/math_utils.dart`). Both are **already
comprehensively unit-tested** in `test/math_utils_test.dart` (verified
2026-06-10):

- `meanPool`: averaging of active tokens, padding exclusion (mask = 0),
  zero-vector degenerate case (no active tokens), single-active-token
  passthrough, returns `Float32List`.
- `l2Normalize`: unit-norm after normalisation, in-place identity, zero-vector
  unchanged, already-unit-norm unchanged, negative components, single-element
  ±1.
- `cosineSimilarity` is also covered.

These run in CI under JIT with **no ORT dependency**. The embed→pool→normalise
correctness the dropped stub was meant to verify is therefore already exercised
at the unit level. No new test is required to land this plan; Phase 2 only
checks that the existing coverage is intact and (if a gap is found) closes it
with a plain unit test — never an ORT-driven one.

### Callers broken by removing `_defaultModelPath()` (Q4)

Removing `_defaultModelPath()` and the no-arg fallback branch from `load()`
changes the contract: a call supplying neither `modelPath` nor `cacheDir` must
now fail fast. **Decision: throw `ArgumentError`** at the top of `load()`,
before any I/O, with the message:

```
Either modelPath or cacheDir must be supplied. Pass an explicit modelPath, or
pass cacheDir (with an optional spec) to download the model on demand. See
ModelCatalog and ModelDownloader.
```

`ArgumentError` (not `StateError`/`UnsupportedError`) is correct: the failure is
a missing required argument, detectable synchronously, independent of platform
or runtime availability.

Verified call sites that break and must be fixed (verified 2026-06-10):

| # | Location | Current | Fix |
|---|---|---|---|
| 1 | `packages/kmdb_inferencing/test/kmdb_inferencing_test.dart:28–38` | passes the bare `OnnxEmbeddingModel.load` tear-off, asserts `throwsA(isA<UnsupportedError>())` | rewrite to assert `throwsA(isA<ArgumentError>())`; update the test name/comment (it currently says "throws when model assets are absent" — the new reason is "no modelPath/cacheDir supplied") |
| 2 | `packages/kmdb_inferencing/example/kmdb_inferencing_example.dart:22,26` | `await OnnxEmbeddingModel.load()` with no args, doc says "throws" | change to a realistic download-on-demand call: `OnnxEmbeddingModel.load(cacheDir: <dir>)` (or `spec: ModelCatalog.lookup(...), cacheDir: ...`); update the surrounding doc comment to describe download-on-demand rather than "throws" |
| 3 | `packages/kmdb/lib/src/search/vec_index_definition.dart:35` | doc-comment example `embeddingModel: await OnnxEmbeddingModel.load(),` | replace the no-arg call with `await OnnxEmbeddingModel.load(cacheDir: cacheDir)` (matching the `kmdb_database.dart:726` example style) |
| 4 | `packages/kmdb/lib/src/query/kmdb_database.dart:83` | doc-comment example `embeddingModel: await OnnxEmbeddingModel.load(), // required for vecIndexes` | replace with `await OnnxEmbeddingModel.load(cacheDir: cacheDir)`; keep the `// required for vecIndexes` note |

`kmdb_database.dart:726` already shows the correct `spec: + cacheDir:` form and
needs **no** change.

### Git history rewrite (Q7)

A tree-only `git rm` leaves the ~133 MB blob in history; every clone still
smudges it via LFS. Per decision 2026-06-10, **purge the blob from history** so
clones stop paying the cost.

```bash
# Preferred tool: git-filter-repo (NOT filter-branch — slower, error-prone,
# and deprecated by Git upstream for this use). Install via `brew install
# git-filter-repo` or `pip install git-filter-repo`.

# From a FRESH clone of the repo (filter-repo refuses to run on a repo with
# uncommitted changes and rewrites all refs):
git filter-repo --path packages/kmdb_inferencing/assets/models/bge-small-en/bge_small.onnx --invert-paths
```

This rewrites every commit that touched the blob, so **all commit SHAs change**.
Coordination required (document in the PR description):

1. The rewrite is performed on `main` and **force-pushed** (`git push --force`).
   Branch protection on `main` must be temporarily relaxed to allow the
   force-push, then restored.
2. **Every team member must re-clone** (simplest) or hard-reset their local
   `main` to the rewritten remote (`git fetch && git reset --hard origin/main`)
   and rebase any in-flight branches onto the new history. Stale local refs that
   still contain the blob will re-introduce it if pushed.
3. The LFS objects on the remote become unreferenced. Run `git lfs prune` (or
   GitHub's LFS object cleanup) after the rewrite to reclaim storage; until
   then the blob still consumes LFS quota even though no commit references it.
4. Open PRs that predate the rewrite will need rebasing or re-opening against
   the new `main`.

Because history rewrite + force-push is disruptive, it is the **final** step
(Phase 3) and is called out explicitly in the PR so a human performs the
force-push and coordinates the team, rather than the implementing agent doing it
silently.

### `.gitattributes` after removal

`.gitattributes` at the repo root declares `*.onnx filter=lfs diff=lfs merge=lfs
-text`. After the blob is gone, no `*.onnx` file remains tracked, so the line is
removed entirely (Phase 3). With no stub fixture introduced, there is no
remaining `.onnx` file to worry about being re-captured by the filter — the
earlier ordering hazard (a stub being LFS-captured) is moot.

## Implementation plan

### Phase 1 — Verify existing embed-pipeline coverage

- [x] Confirm `test/math_utils_test.dart` still covers `meanPool`
  (averaging, padding exclusion, zero-vector, single-token) and `l2Normalize`
  (unit-norm, zero-vector, negative, single-element). If any of those edge
  cases is missing, add it as a plain JIT unit test — **do not** add any test
  that calls `OnnxRuntime.load()` / drives the ORT runtime (it would skip in CI
  and add no coverage).
- [x] No stub fixture, no generator, no `test/fixtures/` directory, no new
  `vocabPath` parameter. This phase produces at most a small unit-test addition;
  most likely it is a no-op confirmation.

### Phase 2 — Remove the LFS fallback from `OnnxEmbeddingModel.load()`

- [x] In `packages/kmdb_inferencing/lib/src/embedding_model.dart`:
  - Add a guard at the top of `load()`: if `modelPath == null && cacheDir ==
    null`, `throw ArgumentError('Either modelPath or cacheDir must be supplied.
    Pass an explicit modelPath, or pass cacheDir (with an optional spec) to
    download the model on demand. See ModelCatalog and ModelDownloader.')`.
  - Delete the `else { resolvedModelPath = _defaultModelPath(); ... }` branch
    (lines 182–186) — only the `modelPath != null` and `cacheDir != null`
    branches remain.
  - Delete the `_defaultModelPath()` method (lines 279–288).
  - Update the `load()` doc comment: remove any "Legacy / LFS assets" /
    "default assets directory" wording; state that `modelPath` or `cacheDir`
    is required and that download-on-demand is the supported mechanism.
- [x] Confirm there are no other references to `_defaultModelPath` in the
  package (`grep -rn _defaultModelPath packages/kmdb_inferencing`).

### Phase 3 — Fix broken callers and doc examples (Q4)

- [x] `test/kmdb_inferencing_test.dart:28–38` — rewrite the assertion to
  `throwsA(isA<ArgumentError>())` and update the test name/comment to
  "throws ArgumentError when neither modelPath nor cacheDir is supplied".
- [x] `example/kmdb_inferencing_example.dart:22,26` — change the no-arg
  `OnnxEmbeddingModel.load()` to a download-on-demand call (`cacheDir:` with an
  appropriate directory) and update the surrounding doc comment so it no longer
  claims `load()` "throws"; describe download-on-demand instead.
- [x] `packages/kmdb/lib/src/search/vec_index_definition.dart:35` — change the
  doc-comment example to `await OnnxEmbeddingModel.load(cacheDir: cacheDir)`.
- [x] `packages/kmdb/lib/src/query/kmdb_database.dart:83` — change the
  doc-comment example to `await OnnxEmbeddingModel.load(cacheDir: cacheDir)`,
  keeping the `// required for vecIndexes` note.
- [x] Leave `kmdb_database.dart:726` unchanged (already correct).
- [x] Run `cd packages/kmdb_inferencing && dart test` and
  `cd packages/kmdb && dart test` to confirm both packages compile and pass.

### Phase 4 — Remove LFS file, filter, and history

- [x] Remove the `*.onnx` line from the repo-root `.gitattributes`:
  ```diff
  -*.onnx filter=lfs diff=lfs merge=lfs -text
  ```
- [x] `git rm packages/kmdb_inferencing/assets/models/bge-small-en/bge_small.onnx`
  and commit the removal together with the `.gitattributes` change.
- [ ] Confirm `git lfs ls-files` no longer lists `bge_small.onnx` and
  `git lfs status` shows no tracked files in `kmdb_inferencing` (verified
  post-commit — still shows in staging, will clear after commit).
- [ ] **History rewrite (human-coordinated — call out in the PR, do not perform
  silently from the agent):** from a fresh clone, run
  `git filter-repo --path
  packages/kmdb_inferencing/assets/models/bge-small-en/bge_small.onnx
  --invert-paths`, then force-push `main` (after relaxing branch protection),
  restore branch protection, and run `git lfs prune` on the remote to reclaim
  the LFS objects. Document the team re-clone / rebase requirement (see the
  "Git history rewrite" investigation section).

### Phase 5 — Documentation and roadmap

- [x] Update `packages/kmdb_inferencing/README.md`: remove references to the
  LFS bundle; add a "Model download" section describing `ModelDownloader` /
  `cacheDir` usage.
- [x] Update `docs/spec/22_semantic_search.md` §"ORT Binary Acquisition":
  note that `bge_small.onnx` is no longer bundled; first use triggers a
  download via `ModelDownloader`.
- [ ] Hand the roadmap edits to **kmdb-architect** (roadmap is the architect's
  to maintain): in `docs/roadmap/0_05.md`, mark "LFS asset removal" `[x]`, and
  rewrite the CI-strategy bullet (lines 96–101) — the chosen strategy is **no
  stub fixture**; embed-pipeline correctness is covered by the existing
  `math_utils_test.dart` unit tests, and ORT-driven inference verification
  remains release-checklist-only (RC-15).
- [ ] Open the PR. The PR description must spell out the history-rewrite +
  force-push + team-re-clone coordination so a human drives that step.

### Testing strategy

- **Automated (CI/JIT):** the existing `math_utils_test.dart` (mean-pool,
  L2-norm) and the rewritten `kmdb_inferencing_test.dart` (`ArgumentError` on
  no-arg `load()`) cover all new behaviour. Both packages' suites
  (`kmdb_inferencing` and `kmdb`) must pass — the `kmdb` doc-comment edits don't
  change behaviour but must still compile.
- **Coverage:** no new ORT-gated test is added, so the 90% bar is unaffected;
  the removed fallback branch reduces uncovered lines if anything.
- **Release checklist:** **no new RC entry is required** — the dropped stub was
  the only thing that would have needed one. The existing RC-15 already covers
  AOT ORT inference at release time. (The next free RC number remains RC-16 for
  future work; this plan does not consume it.)
- **Manual verification post-merge (human):** after the history rewrite,
  confirm a fresh `git clone` does **not** fetch the 133 MB blob (e.g.
  `git lfs ls-files` is empty and clone size dropped). This is the headline
  benefit and can only be verified against the rewritten remote.

## Review — 2026-06-10 (kmdb-plan-reviewer)

**Status set to `Questions`.** The problem is real, well-scoped, and the
high-level approach is sound. But the plan has one mischaracterised technical
risk (the stub-fixture generator), several missing edits that Phase 4 forces
(broken test, example, doc-comment examples, undefined post-removal `load()`
contract), a roadmap conflict on the stub dimension, and some factual slips. It
is not yet mechanically implementable. Blocking items are listed as new open
questions Q3–Q7; resolve those and fix the slips and this clears to
`Investigated`.

### Problem statement assessment

Sound and worth doing. The LFS file is real and is **~133 MB**, not ~44 MB as
the problem statement and Q1 state (verified: `git lfs ls-files` →
`bge_small.onnx`; on-disk size 133,041,945 bytes). Both prerequisites the
roadmap named (betto_onnxrt Stage A download path; CI strategy) are genuinely
met per `docs/roadmap/0_05.md`. The "keep the non-ONNX files" scope is correct —
`bert_tokenizer_test.dart` does skip when `vocab.txt` is absent (verified
`_vocabAvailable`). Fix the size figure everywhere it appears.

### Proposed solution assessment — strengths

- Retiring the LFS fallback in favour of `ModelSpec + cacheDir` is the right
  direction; `OnnxEmbeddingModel.load` already implements that path
  (verified `embedding_model.dart` lines 168–181).
- The `embed()` signature the test relies on — `(Float32List, bool)` — and
  `spec.meta['dimensions']` as the dim source are accurate (lines 115, 219, 260).
- `ModelSpec(id:, files: const {}, meta: {'dimensions': N})` is a valid
  construction (verified betto_onnxrt `model_spec.dart`: `files` required but may
  be empty, `meta` optional). The test uses `modelPath`, so the empty `files`
  map is never resolved — fine.
- Auto-skip-when-ORT-absent is a real, established pattern. Cite the exact
  precedent for the implementer: `_ortLibraryAvailable()` in betto_onnxrt
  `test/onnx_session_test.dart` (lines 49–68) gated by `skip: ortAvailable ? …`.

### Proposed solution assessment — the big weakness (Q3)

**The stub-fixture generator is described as a near-mechanical adaptation of
`betto_onnxrt/tool/generate_test_fixture.dart`; it is not.** I read that
precedent. It hand-encodes ONNX protobuf with no deps, but it ONLY knows how to
emit: a single `Identity` node (op_type string, **no node attributes**),
`float32` ValueInfo (`elem_type` hardcoded to 1), and **fixed integer dims only**
(`_tensorShape(List<int>)`). It has **no** encoder for `AttributeProto`, no
encoder for `TensorProto` (constant tensor values), no `int64` element type, no
multi-node graph, and no dynamic dimension.

The plan's four-node graph needs every one of those things:
- `Constant(value=int64[[D]])` — `value` is a **TensorProto attribute**
  (AttributeProto + TensorProto encoding — entirely absent from the precedent).
- `ConstantOfShape(value=1.0f)` — another TensorProto-valued attribute.
- Three `int64` inputs — `elem_type = 7`, which the precedent's `_typeProto`
  hardcodes to 1.
- Dynamic `seqLen` — the plan says `dim_value = 0`, but in ONNX a `dim_value` of
  0 is a literal zero-length dimension. A symbolic/unknown dim is expressed with
  `dim_param` (a string) or by omitting the dim entirely. `dim_value = 0` is
  likely wrong and would either be rejected or fix seqLen at zero.

This is a genuine design task, not a checklist item. **Q3 records the decision:**
either (a) commit to hand-encoding AttributeProto/TensorProto/int64/dynamic-dim
in the generator and have the plan specify that encoding in enough detail that
Sonnet doesn't invent the protobuf field numbers, or (b) avoid the
attribute-heavy ops. A much simpler graph that needs **zero attributes and zero
constant tensors** is available: a single `MatMul` or even just summing inputs
won't give all-ones; but an all-ones output of the right shape can be produced by
`Shape(input_ids) → ... ` still needs Concat+ConstantOfShape. The cleanest
attribute-free option is to **drop the all-ones requirement**: e.g. cast/identity
a slice so the output is shaped from the input, or simply accept that the test
asserts only `embedding.length == D` and `norm == 1.0` for *any* non-degenerate
output, which a `ReduceSum`/`Cast` graph can satisfy without constant tensors.
The reviewer's recommendation is (a) only if the implementer is given the exact
AttributeProto/TensorProto wire layout in the plan; otherwise pick a graph whose
ops take no tensor-valued attributes. **This must be decided before
`Investigated`** — as written, Phase 1 hands Sonnet an under-specified protobuf
encoding task.

### Architecture fit

- Aligns with the documented direction: ONNX models are data assets downloaded
  on first use (roadmap 0_05.md, §22). No sync/storage-engine invariants are
  touched — `$vec:` namespaces are already sync- and cache-excluded.
- The `local/config.json` `EmbeddingModelConfig` typedef still requires
  `modelPath` (per prior review notes); this plan does not change that path and
  doesn't need to. No conflict, but the implementer should not be surprised that
  removing `_defaultModelPath()` leaves the explicit-`modelPath` path intact.

### Risk & edge cases — missing edits Phase 4 forces (Q4)

Phase 4 removes `_defaultModelPath()` and the no-arg branch but does not
enumerate the fallout. Verified call sites of `OnnxEmbeddingModel.load`:

1. **`test/kmdb_inferencing_test.dart:34`** passes the bare `OnnxEmbeddingModel.load`
   tear-off and asserts `throwsA(isA<UnsupportedError>())`. After Phase 4,
   calling `load()` with no `modelPath`/`cacheDir`/`spec` no longer hits a
   missing-file `UnsupportedError`. **What should it throw instead?** The plan
   never defines the post-removal contract for an argument-less call. Options:
   `ArgumentError`/`StateError` ("supply modelPath or spec+cacheDir"). This test
   must be rewritten to match, and the plan must state the new exception type.
2. **`example/kmdb_inferencing_example.dart:26`** calls `OnnxEmbeddingModel.load()`
   with no args. It will break or change behaviour — Phase 5 doesn't mention it.
3. **Doc-comment examples** showing `OnnxEmbeddingModel.load()` with no args in
   `kmdb/lib/src/search/vec_index_definition.dart:35`,
   `kmdb/lib/src/query/kmdb_database.dart:83` and `:726`. These become
   misleading after Phase 4; Phase 5 only lists the inferencing README and §22.

**Q4 records the post-removal `load()` no-arg contract** (exception type +
message), and the implementation checklist must add the four edits above.

### Risk & edge cases — the "CI-safe inference test" framing is misleading (Q5)

The secondary goal is described as a "CI-safe inference test" and Phase 2 says
"Confirm existing tests still pass". But under plain `dart test` JIT — exactly
what `make pre_commit` and CI run — `OnnxRuntime.load()` cannot find
`libonnxruntime.*` (the native-assets dir is not on the OS library search path in
JIT; this is precisely why betto_onnxrt's OnnxSession tests auto-skip, see RC-15
"Why not automated"). **The new inference test will therefore always skip in
CI.** It only executes under a `dart build` AOT pipeline with
`DYLD_LIBRARY_PATH`/`LD_LIBRARY_PATH` set — i.e. at release time.

Consequences the plan must own:
- It adds **no automated CI coverage** and gives **no coverage credit** toward
  the 90% bar. Describe it accurately as a release-checklist verification, not a
  "CI-safe" test.
- The real value is the RC entry. That part is correct and worth doing.
- Q5 is just confirmation that this framing is understood and corrected in the
  prose — not a true open design choice, but flag it so the implementer/QA don't
  expect green inference assertions in CI.

### Risk & edge cases — Phase ordering & .gitattributes (already partly caught)

The plan notices that the `*.onnx` LFS filter will capture `bge_stub.onnx` and
that the fixture must be committed only after the filter is dropped. Good catch,
but the Phase 1 / Phase 3 ordering is currently self-contradictory: Phase 1 step
2 says "commit `test/fixtures/bge_stub.onnx`" while its own parenthetical says
that must wait for Phase 3. **Reorder so the generator is written in Phase 1 but
the fixture is generated and committed only in Phase 3, after the filter is
removed** (Phase 3 already has a generate+commit step — make Phase 1 stop at
"write and locally run the generator; do not commit the .onnx yet"). Alternative:
add a negative override `test/fixtures/** -filter -diff -merge text` to
`.gitattributes` so fixtures are never LFS regardless of the `*.onnx` rule — but
since the plan removes the `*.onnx` rule entirely, simple reordering is cleaner.
No open question; just fix the checklist ordering.

### Factual slips to correct (non-blocking but must be fixed before Investigated)

- **Model size:** ~133 MB, not ~44 MB (problem statement and Q1).
- **RC number:** next available is **RC-16** (last is RC-15). The plan says both
  "RC-17 or next available" and "next available after RC-15" — settle on RC-16.
- **`vocabPath` design (Phase 2):** the recommended option (b) — add an optional
  `vocabPath` to `load()` — is reasonable, but note the current derivation is
  `p.join(p.dirname(modelPath), 'vocab.txt')` (line 167). Specify that
  `vocabPath`, when supplied, overrides this for **both** the explicit-`modelPath`
  branch and is ignored on the `cacheDir` branch (where `vocab` comes from
  `resolved.filePaths['vocab']`). Otherwise the implementer must guess the
  interaction.
- **Q1 (D=4) conflicts with the roadmap.** `docs/roadmap/0_05.md` lines 100–101
  explicitly define the chosen CI strategy as a BGE-shaped stub of **dim 384**
  ("int64 tokens → float32 embeddings dim 384"). The plan's D=4 recommendation
  silently overrides that. The reviewer agrees D=4 is *technically* sufficient
  (mean-pool and L2-norm are dimension-agnostic), but this is a roadmap deviation
  that must be made explicit and accepted — see Q6. If D=4 is chosen, update the
  roadmap line so the two documents agree (note: roadmap edits are the
  kmdb-architect's job, so record the decision and hand the roadmap edit off).

### New open questions (must be resolved to reach `Investigated`)

- [ ] **Q3 — Stub graph encoding.** Decide the fixture graph and commit to one of:
  (a) hand-encode AttributeProto + TensorProto + int64 ValueInfo + dynamic dim in
  the generator, with the plan specifying the protobuf field numbers so Sonnet
  doesn't invent them; or (b) choose an attribute-free, constant-tensor-free graph
  that still yields a shape-`[1,seqLen,D]` float32 output the embed pipeline can
  pool/normalise. The current "follows generate_test_fixture.dart" framing is
  not accurate for the proposed four-node graph. _Reviewer lean: (b) if it can be
  found; (a) only with full wire-format detail in the plan._
- [ ] **Q4 — Post-removal `load()` no-arg contract.** After `_defaultModelPath()`
  is deleted, what does `OnnxEmbeddingModel.load()` (no `modelPath`, no
  `cacheDir`, no `spec`) throw, and with what message? Update
  `test/kmdb_inferencing_test.dart`, `example/kmdb_inferencing_example.dart`, and
  the three doc-comment examples (`vec_index_definition.dart:35`,
  `kmdb_database.dart:83`, `:726`) to match. _Reviewer lean: `ArgumentError`
  naming the required parameters._
- [ ] **Q5 — Confirm the test is release-checklist-only, not CI.** Acknowledge in
  the plan that the inference test always skips under JIT/CI and only runs under
  AOT at release time; remove the "CI-safe" framing and the "confirm existing
  tests still pass" implication of new green inference assertions. _Confirmation,
  not a design choice._
- [ ] **Q6 — Stub dimension vs roadmap (supersedes Q1).** D=4 or D=384? The
  roadmap specifies 384. If D=4 is chosen, record the deviation and hand the
  roadmap-line update to kmdb-architect. _Reviewer: either is correct; pick one
  and make the two docs agree._
- [ ] **Q7 — Git history rewrite scope.** The plan's `git rm` + `git lfs untrack`
  removes the file from the working tree and future commits, but the ~133 MB blob
  remains in history (every `git clone` still pays for it via LFS smudge unless
  history is rewritten). Is removing it from the tip sufficient, or is a history
  rewrite (`git filter-repo`) / LFS-object purge in scope? This materially
  affects whether the stated benefit ("every clone must fetch it") is actually
  realised. _Reviewer: clarify scope; a tree-only removal does not stop existing
  history from carrying the blob, though it stops growth and is the low-risk
  option. State explicitly which is intended._

### Recommendation

**Proceed, but resolve Q3–Q7 and fix the factual slips first.** This is a
worthwhile cleanup with a sound shape. The blocking gap is Q3 (the fixture
generator is under-specified for the proposed graph) and Q4 (Phase 4 breaks a
test, an example, and three doc examples with no defined replacement contract).
Q5/Q6 are quick to close; Q7 changes whether the headline benefit is real. Once
those are settled and the checklist absorbs the missing edits and ordering fix,
this clears to `Investigated`.

## Review — 2026-06-10 (kmdb-plan-reviewer, second pass) — Status set to `Investigated`

All open questions resolved by user decision (2026-06-10) and the plan rewritten
accordingly. Verdict: **Investigated — ready to implement.**

**What the decisions changed, and why this clears the bar:**

- **Stub fixture dropped (Q1/Q3/Q5/Q6).** This removes the single biggest
  implementation risk — the under-specified ONNX protobuf encoding (Q3) that
  required hand-rolling `AttributeProto`/`TensorProto`/int64-ValueInfo/dynamic
  dims that `betto_onnxrt`'s precedent generator does not support. It also
  removes the misleading "CI-safe inference test" framing (the test would always
  skip under JIT) and the roadmap dim-384 conflict. Net: the plan no longer asks
  Sonnet to make any protobuf design decisions.
- **New finding that strengthens the decision:** the embed pipeline's only
  non-trivial pure logic, `meanPool` and `l2Normalize`, is *already*
  comprehensively unit-tested in `test/math_utils_test.dart` (verified — covers
  averaging, padding exclusion, zero-vector, unit-norm, negatives,
  single-element). So dropping the stub costs **no real coverage**; the
  "secondary goal" was largely already met. Phase 1 is now a confirmation step,
  not a build step. This is recorded so the implementer does not duplicate those
  tests.
- **`_defaultModelPath()` removed (Q2)** with a concrete post-removal contract:
  no-arg `load()` throws `ArgumentError` synchronously, with a specified
  message. The four broken callers (test:28–38, example:22/26,
  `vec_index_definition.dart:35`, `kmdb_database.dart:83`) are enumerated in a
  table with exact fixes; `kmdb_database.dart:726` confirmed already-correct.
  This closes the Q4 gap that previously blocked.
- **Git history rewrite in scope (Q7)** via `git filter-repo` (correctly
  preferred over `filter-branch`), with the force-push / branch-protection /
  team-re-clone / `git lfs prune` coordination documented and explicitly flagged
  as a human-driven step in the PR rather than silent agent action. This makes
  the headline benefit ("clones stop paying the LFS cost") actually real.
- **Factual slips fixed:** model size now ~133 MB throughout; the RC confusion is
  resolved by noting **no new RC entry is needed** (RC-16 stays free); the
  Phase 1/Phase 3 ordering contradiction is gone because there is no longer a
  stub `.onnx` to sequence around the LFS filter removal.

**One handoff to track, not a blocker:** the roadmap edit (`docs/roadmap/0_05.md`
lines 96–101 still describe the now-dropped dim-384 stub strategy) belongs to
kmdb-architect, not this plan's implementer. Phase 5 records this correctly. The
implementer should not edit the roadmap directly.

No remaining ambiguity. A competent engineer could execute every checklist item
without making a design decision.

## Summary

_To be completed after implementation._
