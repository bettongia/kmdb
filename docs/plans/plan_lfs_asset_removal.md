# LFS Asset Removal — Replace bundled BGE model with download-on-demand

**Status**: Open

**PR link**: _(pending)_

**Roadmap**: [v0.05 — LFS asset removal](../roadmap/0_05.md#lfs-asset-removal)

## Problem statement

`packages/kmdb_inferencing/assets/models/bge-small-en/bge_small.onnx` is tracked
by Git LFS. It is a ~44 MB binary that every `git clone` must fetch from LFS
storage, even for developers who never run semantic search. LFS itself is an
operational dependency: LFS bandwidth counts against GitHub's metered quota,
and a missing LFS credential silently produces a text pointer stub where a
binary file is expected, causing opaque runtime failures.

The removal is now unblocked: `betto_onnxrt` Stage A established the
`ModelDownloader` + `ModelCatalog` download-on-demand path, proven in CI.
`OnnxEmbeddingModel.load(spec:, cacheDir:)` already supports this path. The
LFS bundle is a redundant fallback that should be retired.

**Scope:** Remove `bge_small.onnx` from Git LFS and from the repository. The
non-ONNX files in `assets/models/bge-small-en/` (`vocab.txt`,
`tokenizer.json`, `tokenizer_config.json`, `special_tokens_map.json`,
`config.json`) are plain-git, small, and **must remain** — `BertTokenizer`
loads `vocab.txt` from this directory and `bert_tokenizer_test.dart` skips
all tokenizer tests when it is absent.

Secondary goal: add a meaningful CI-safe inference test for
`OnnxEmbeddingModel`. The current test suite only verifies that `load()`
throws `UnsupportedError` when the model is absent; it cannot exercise the
embed→pool→normalise pipeline because the real BGE model is 44 MB and
requires a live ORT binary. A BGE-shaped stub fixture (tiny, plain binary,
no real weights) fixes this.

## Open questions

- [ ] **Q1 — Stub fixture hidden dimension.** The fixture's `last_hidden_state`
  output has shape `[1, seqLen, D]`. Using D=4 keeps the fixture under 1 KB
  and avoids embedding a large constant tensor. The inference test uses a
  custom `ModelSpec` with `meta: {'dimensions': 4}` so `OnnxEmbeddingModel`
  reads `hiddenDim = 4`. Is D=4 acceptable, or should it be 384 (the real BGE
  dimension) to exercise the full-size code path? _Recommendation: D=4. The
  mean-pool and L2-normalisation paths are dimension-agnostic; exercising them
  at D=4 is equivalent for correctness verification._

- [ ] **Q2 — Remove or keep `_defaultModelPath()`.** `OnnxEmbeddingModel.load()`
  falls back to `<executableDir>/assets/models/bge-small-en/bge_small.onnx`
  when neither `modelPath` nor `cacheDir` is supplied. After LFS removal this
  path will never exist at runtime. Should the fallback be removed (callers
  must explicitly supply `spec+cacheDir` or `modelPath`) or replaced with a
  `throw UnsupportedError` that describes the download-on-demand path?
  _Recommendation: remove the fallback entirely. The doc comment already
  labels it "Legacy / LFS assets". Keeping a dead fallback misleads readers._

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
| `bge_small.onnx` | ~44 MB | ✅ LFS | ❌ Remove |
| `vocab.txt` | ~230 KB | plain git | ✅ Keep |
| `tokenizer.json` | ~700 KB | plain git | ✅ Keep |
| `tokenizer_config.json` | ~1 KB | plain git | ✅ Keep |
| `special_tokens_map.json` | ~1 KB | plain git | ✅ Keep |
| `config.json` | ~1 KB | plain git | ✅ Keep |

### BGE-shaped stub fixture

The stub must satisfy `OnnxEmbeddingModel`'s inference call:

```dart
_session.run(
  inputs: {
    'input_ids':      OnnxTensor.fromInt64([1, seqLen], ...),
    'attention_mask': OnnxTensor.fromInt64([1, seqLen], ...),
    'token_type_ids': OnnxTensor.fromInt64([1, seqLen], ...),
  },
  outputNames: ['last_hidden_state'],
);
// output shape: [1, seqLen, D] float32
```

The stub requires:
- Three named `int64` inputs with dynamic sequence length (`dim_value = 0`)
- One `float32` output named `last_hidden_state` of shape `[1, seqLen, D]`

ONNX graph (using opset 9 ops, all ORT-supported):

```
Constant(value=int64[[D]])           → hidden_dim_tensor   # int64[1]
Shape(input_ids)                     → ids_shape            # int64[2] = [1, seqLen]
Concat([ids_shape, hidden_dim_tensor], axis=0) → out_shape  # int64[3] = [1, seqLen, D]
ConstantOfShape(out_shape, value=1.0f)         → last_hidden_state  # float32[1, seqLen, D]
```

The output is all-ones. The mean-pool step averages over the `seqLen`
dimension using the attention mask (all positions 1 for a real input), giving
a `[D]`-element all-ones vector. L2-normalisation produces
`[1/√D, …, 1/√D]` — a valid unit vector. The inference test can assert
`norm ≈ 1.0` (within float32 precision).

The fixture is generated by `tool/generate_bge_fixture.dart`, following the
pattern of `betto_onnxrt/tool/generate_test_fixture.dart` (raw ONNX protobuf
encoding without external dependencies). The generated file is committed to
`test/fixtures/bge_stub.onnx` (plain binary, no LFS).

### Inference test design

The new test in `test/kmdb_inferencing_test.dart` (or a new
`test/onnx_embedding_model_test.dart`):

```dart
// Auto-skip when ORT binary is not available (same pattern as betto_onnxrt).
// Uses OnnxRuntime.load() — skips on UnsupportedError.

test('embed() with BGE-stub fixture produces a unit vector', () async {
  final stubSpec = ModelSpec(
    id: 'bge-stub-fixture',
    files: const {},
    meta: const {'dimensions': 4},
  );
  // Resolve vocab.txt from the existing plain-git assets directory.
  final vocabPath = /* assets/models/bge-small-en/vocab.txt */;
  final stubOnnxPath = /* test/fixtures/bge_stub.onnx */;

  final model = await OnnxEmbeddingModel.load(
    spec: stubSpec,
    modelPath: stubOnnxPath,
    // vocabPath derived from p.dirname(stubOnnxPath) — won't exist; supply
    // via the explicit path constructor or extend load() to accept vocabPath.
    // See Phase 2 below.
  );
  final (embedding, truncated) = await model.embed('hello world');
  model.dispose();

  expect(embedding.length, 4);
  expect(truncated, isFalse);
  final norm = sqrt(embedding.fold(0.0, (s, x) => s + x * x));
  expect(norm, closeTo(1.0, 1e-5));
});
```

**Note on `load()` + vocab path**: the current `load(modelPath:)` derives
`vocabPath` as `p.dirname(modelPath)/vocab.txt`. If `bge_stub.onnx` lives in
`test/fixtures/`, that dirname won't contain `vocab.txt`. Two options:
- (a) Copy/symlink `vocab.txt` into `test/fixtures/` — simple but redundant.
- (b) Add an optional `vocabPath` parameter to `OnnxEmbeddingModel.load()`.
- (c) Extend `load(modelPath:)` to accept a `vocabPath` override.
_Recommendation: option (b) — a single optional `vocabPath` parameter._

Since this test requires the ORT binary to be staged, add it to
`docs/spec/28_release_checklist.md` (RC-17 or next available number) alongside
the existing RC-15 entry.

### Removing `bge_small.onnx` from LFS

```bash
# Remove the file from LFS tracking and from git history on main.
git lfs untrack "*.onnx"          # remove the filter line from .gitattributes
git rm packages/kmdb_inferencing/assets/models/bge-small-en/bge_small.onnx
# Remove stale LFS objects (optional — does not affect other developers):
# git lfs prune
```

After `git rm`, the `.gitattributes` `*.onnx` line must also be removed
(see Phase 3) since no `*.onnx` files remain tracked in the repo.

## Implementation plan

### Phase 1 — BGE-shaped stub fixture

- [ ] Write `packages/kmdb_inferencing/tool/generate_bge_fixture.dart`:
  - Encode the four-node graph above in raw ONNX protobuf (no external deps)
  - Use `ir_version = 8`, opset 9 (`Shape`, `Concat`, `Constant`,
    `ConstantOfShape` are all opset ≤ 9)
  - Hidden dim D = 4; all three inputs declared with dynamic seq_len
    (`dim_value = 0`)
  - Write output to `test/fixtures/bge_stub.onnx`
  - Add Apache 2.0 license header
- [ ] Run `dart run tool/generate_bge_fixture.dart` and commit
  `test/fixtures/bge_stub.onnx` (confirm it is NOT picked up by the `*.onnx`
  LFS filter — it will be, so this step must happen **after** Phase 3 removes
  the filter, or exclude the fixtures dir in `.gitattributes` first)
- [ ] Verify the stub is valid: `dart run tool/generate_bge_fixture.dart` +
  inspect file size (expected: < 200 bytes)

### Phase 2 — Inference test (ORT-gated)

- [ ] Add optional `vocabPath` parameter to `OnnxEmbeddingModel.load()`:
  ```dart
  static Future<OnnxEmbeddingModel> load({
    ModelSpec? spec,
    String? cacheDir,
    String? modelPath,
    String? vocabPath,   // ← new; overrides the dirname(modelPath) derivation
    Tokenizer? tokenizer,
    DownloadProgress? onProgress,
  })
  ```
- [ ] Add `test/fixtures/` directory to `kmdb_inferencing` (create it)
- [ ] Write the inference test in `test/onnx_embedding_model_test.dart`:
  - Skip automatically if `OnnxRuntime.load()` throws `UnsupportedError`
    (ORT binary not staged — same pattern as `betto_onnxrt` OnnxSession tests)
  - Load stub model with explicit `vocabPath` pointing to
    `assets/models/bge-small-en/vocab.txt`
  - Call `embed('hello world')` and assert `embedding.length == 4` and
    `l2Norm ≈ 1.0`
  - Call `embed('')` (empty input) and assert it does not throw
- [ ] Add entry to `docs/spec/28_release_checklist.md` describing the test
  and the ORT binary requirement (next available RC number after RC-15)
- [ ] Confirm existing tests still pass: `cd packages/kmdb_inferencing && dart test`

### Phase 3 — Remove LFS file and filter

- [ ] Remove the `*.onnx` LFS filter from `.gitattributes`:
  ```diff
  -*.onnx filter=lfs diff=lfs merge=lfs -text
  ```
- [ ] Stage and commit the `.gitattributes` change first so subsequent steps
  don't re-add `bge_stub.onnx` to LFS
- [ ] `git rm packages/kmdb_inferencing/assets/models/bge-small-en/bge_small.onnx`
- [ ] Run `dart run tool/generate_bge_fixture.dart` (now that the LFS filter
  is removed) and commit `test/fixtures/bge_stub.onnx` as a plain binary
- [ ] Confirm `git lfs status` shows no tracked files in `kmdb_inferencing`

### Phase 4 — Remove LFS fallback from `OnnxEmbeddingModel.load()`

- [ ] Delete `_defaultModelPath()` from `embedding_model.dart` (resolves Q2)
- [ ] Remove the no-arg / `cacheDir == null && modelPath == null` branch from
  `load()` — callers must now supply either `modelPath` or `cacheDir`
- [ ] Update the `load()` doc comment: remove the "Legacy / LFS assets"
  section; update the "default assets directory" note to describe the
  download-on-demand path as the only supported mechanism
- [ ] Confirm `make pre_commit` passes

### Phase 5 — Documentation

- [ ] Update `packages/kmdb_inferencing/README.md`: remove references to the
  LFS bundle; add a "Model download" section describing `ModelDownloader`
  usage
- [ ] Update `docs/spec/22_semantic_search.md` §"ORT Binary Acquisition":
  note that `bge_small.onnx` is no longer bundled; first use triggers a
  download via `ModelDownloader`
- [ ] Update `docs/roadmap/0_05.md`: mark LFS asset removal `[x]`
- [ ] Open PR

## Summary

_To be completed after implementation._
