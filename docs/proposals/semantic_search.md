# Semantic text search

Semantic search handles "intent" and "themes," allowing a search for "memory
leak" to find documents discussing "garbage collection issues" even if the words
don't match.

The approach used in kmdb will be to use a small embedding model to generate the
embeddings for both the indexed field and the user query. The model will be
pre-packaged with the kmdb package - it will not be possible to select a
different model.

A [spike solution (bge_embeddings)](../../spikes/bge_embeddings/) has been
prepared in order to validate the viability of the approach and configure the
FFI bindings against the ONNX runtime.

## Example

A document field being indexed using the semantic indexer will go through the
following process:

```
text input  →  tokenizer (Dart)  →  ONNX inference  →  mean pool + normalize  →  embedding vector
```

- `text input`: The value of the document field
- `tokenizer`: This will be the same tokenizer used in the Lexical indexing
  system.
- `ONNX inferencer`: Uses the ONNX runner to perform the inferencing
- `mean pool + normalize`: is described in the `math_utils.dart` code in the
  spike solution.

### Spike solution

A [spike solution (bge_embeddings)](../../spikes/bge_embeddings/) has been
prepared in order to validate the viability of the approach and configure the
FFI bindings against the ONNX runtime.

Running the following command provides the normalized 384-dim vector (as a JSON
array) constructed from the input text:

```sh
cat sample.txt | dart bin/embed.dart >sample.out
```

The first entries in `sample.out` appear as follows:

```json
[-0.07721628383415412,0.03673409050198489,0.03330454097121675,0.02108989652240076,-0.031751226672150155,-0.002696639549431111,-0.04909326037047926,-0.012217435974202587,0.021918372141368304,-0.04907746934157675,-0.051221672782060725,-0.07480958737533583,0.006425653074367868,0.04452357794339675,0.09581140635971289,0.019036522849333732,-0.00844384495910596,0.10933875708540869,-0.017508018680764223,-0.049802242625170634,0.09278090358391061,-0.10388749391167917,0.0490493211316716,-0.01149763019952789,0.011815127116102553,0.028726760708876573,-0.018008032568614954,...]
```

With an input size of 1.5Kb (sample.txt), the resulting output is about 9Kb.

Running the following will output the token count and token list:

```sh
cat sample.txt | dart bin/tokens.dart
```

Output:

```sh
Count : 290
Tokens: ["[CLS]","b","##ge","landmark","em","##bed","##ding","a","chunk","##ing","##-","##free","em","##bed","##ding","method","for","retrieval","augmented","long","##-","##con","##text","large","language","models","https","ar","##xi","##v","org","abs","240","##2","115","##7","##3","large","language","models","ll","##ms","call","for","extension","of","context","to","handle","many","critical","applications","however","the","existing","approaches","are","prone","to","expensive","costs","and","inferior","quality","of","context","extension","in","this","work","we","propose","##ex","##tens","##ible","em","##bed","##ding","which","realizes","high","##-","##qual","##ity","extension","of","ll","##m","##'","##s","context","with","strong","flexibility","and","cost","##-","##ef","##fect","##ive","##ness","ex","##tens","##ible","em","##bed","##ding","stand","as","an","enhancement","of","typical","token","em","##bed","##ding","which","represents","the","information","for","an","ex","##tens","##ible","scope","of","context","instead","of","a","single","token","by","lever","##aging","such","compact","input","units","of","higher","information","density","the","ll","##m","can","access","to","a","vast","scope","of","context","even","with","a","small","context","window","ex","##tens","##ible","em","##bed","##ding","is","systematically","opt","##imi","##zed","in","architecture","and","training","method","which","leads","to","multiple","advantages","1","high","flexibility","of","context","extension","which","flex","##ibly","supports","ad","##-","##ho","##c","extension","of","diverse","context","lengths","2","strong","sample","efficiency","of","training","which","enables","the","em","##bed","##ding","model","to","be","learned","in","a","cost","##-","##ef","##fect","##ive","way","3","superior","compatibility","with","the","existing","ll","##ms","where","the","ex","##tens","##ible","em","##bed","##ding","can","be","seam","##lessly","introduced","as","a","plug","##-","##in","component","comprehensive","evaluation","##s","on","long","##-","##con","##text","language","modeling","and","understanding","tasks","verify","ex","##tens","##ible","em","##bed","##ding","as","an","effective","efficient","flexible","and","compatible","method","to","extend","the","ll","##m","##'","##s","context","[SEP]"]
```

### Approximate embedding size for a 10 page article

BGE-small (384 dimensions):

- Each dimension is a 64-bit float = 8 bytes
- One vector = 384 × 8 = 3,072 bytes (~3KB)

**How many chunks from a 10-page article?**

A typical academic page is ~500 words / ~650 tokens. Ten pages ≈ 6,500 tokens.
With a 400-token chunk size and 50-token overlap:

- Effective step = 350 tokens per chunk
- 6,500 / 350 ≈ ~19 chunks

**Total storage:**

| Model               | Vectors | Size per vector | Total |
| ------------------- | ------- | --------------- | ----- |
| BGE-small (float64) | ~19     | 3KB             | ~57KB |
| BGE-small (float32) | ~19     | 1.5KB           | ~28KB |

The vectors themselves are tiny. Even at 1,000 articles that's only 28–114MB
depending on model and precision. float32 is almost universally used in practice
— the precision loss versus float64 is negligible for cosine similarity search,
and it halves your storage and memory bandwidth. You'd also want to store chunk
metadata alongside the vectors (article ID, chunk index, character offsets,
maybe the raw text for retrieval), but that's typically smaller than the vectors
themselves unless you store the full chunk text, in which case add roughly 400
tokens × ~5 bytes ≈ 2KB per chunk for the text.

## Design

### Embedding Model Selection

The [BGE Small En v1.5](https://huggingface.co/BAAI/bge-small-en-v1.5) model
will be used in this work. The model features:

- ~127MB ONNX, 384 dimensions, handles up to 512 tokens
- Consistently outperforms MiniLM-L6 on retrieval benchmarks despite similar
  size
- Specifically strong on passage retrieval, which maps well to document field
  search

### Model Distribution

The model and its supporting assets (`vocab.txt`, `tokenizer_config.json`) are
bundled directly within the `kmdb` package under `assets/models/bge-small-en/`.

This is practical because all kmdb packages carry `publish_to: none` — they are
distributed as source dependencies rather than through pub.dev, so the pub.dev
100MB package size limit does not apply.

The binary model file (`bge_small.onnx`, ~127MB) is tracked in the repository
using **Git LFS** to avoid bloating the git object store. Supporting text files
(`vocab.txt`, `tokenizer_config.json`) are tracked normally.

The ONNX runtime loads the model from its bundled path at `KmdbDatabase.open()`
time. No internet access or user configuration is required.

#### Future work

The bundled approach is appropriate while kmdb is in active development and
`publish_to: none`. Once the package is ready for broader distribution the
following options should be evaluated:

- **Configurable model path** — allow the caller to supply an alternative ONNX
  file at `open()` time, enabling custom or updated models without a package
  update.
- **On-demand download** — fetch the model on first use and cache it in the
  device's application support directory, reducing the package footprint for
  users who do not use semantic search.

> **pub.dev publishing note:** The bundled model (~127MB) exceeds pub.dev's
> 100MB package archive limit. Publishing `kmdb` to pub.dev will require
> resolving this first — likely by moving to on-demand download or splitting
> the model into a separate package that is excluded from the pub.dev tarball.
> This must be addressed before any pub.dev release is attempted.

### Tokenisation

The BERT tokenizer pipeline has two stages:

1. **Word segmentation** — the text is split into whole words using a
   `Tokeniser` implementation (UAX #29 / [`icu_tokenizer`](../../spikes/icu_tokenizer)
   spike). This stage is shared with the lexical search pipeline.
2. **WordPiece subword splitting** — each word is further split against the
   model vocabulary, producing subword token IDs (e.g. `[CLS]`, `##vest`,
   `##ig`) consumed by the ONNX model.

The two stages produce fundamentally different output: lexical search ends at
normalised whole-word stems (`investig`), while the BERT pipeline continues to
numeric subword IDs for model inference.

`BertTokenizer` accepts a `Tokeniser` in its constructor; `RegExpTokeniser` is
the default. The `IcuTokeniser` (ICU FFI, full UAX #29 compliance) can be
substituted where available — both produce equivalent results for English-language
prose and technical identifiers (see
[icu_tokenizer spike](../../spikes/icu_tokenizer) for the investigation findings).

### Token limit and truncation

BGE Small En v1.5 accepts at most 512 tokens (510 usable after `[CLS]` and
`[SEP]`). At roughly 1.3 subword tokens per word, this covers approximately
350–400 words — sufficient for the document field values this proposal is scoped
to (titles, descriptions, abstracts, notes).

If a field value exceeds the token limit, the first 510 tokens are embedded and
the remainder is discarded. A `truncated: true` flag is recorded in the index
metadata for that entry so the information loss is visible.

#### Chunking is out of scope

Chunking (splitting a value into multiple overlapping windows and storing one
vector per chunk) is explicitly out of scope for this proposal. It is the
appropriate strategy for large attachments such as articles and documents, which
are the domain of the [vault](vault.md) proposal. The
[bge_embeddings spike](../../spikes/bge_embeddings) implements a basic chunking
approach as a preview of what vault-level semantic search will require.

Users who need to semantically search article-length text should store that
content as a vault attachment rather than a document field value.

### Embeddings & Similarity Metric

Text is converted into floating-point arrays (embeddings) using the selected
model. The similarity between the query vector ($A$) and a document vector ($B$)
is measured using cosine similarity:

$$\text{similarity} = \cos(\theta) = \frac{\sum_{i=1}^{n} A_i B_i}{\sqrt{\sum_{i=1}^{n} A_i^2} \sqrt{\sum_{i=1}^{n} B_i^2}}$$

This is implemented in the
[`cosineSimilarity`](../../spikes/bge_embeddings/lib/src/math_utils.dart)
function.

### Index Structure

The index uses three key types in the KV store, all in `$vec:` system namespaces
exempt from the session object cache and materialised view cache (for the same
reasons as `$fts:` — see [Lexical Search §Cache exemption](lexical_search.md)):

```
$vec:{ns}:{field}:{docId}           →  Uint8List (384 bytes, SQ8 quantized)
$vec:corpus:{ns}:{field}            →  { n: int }
$vec:truncated:{ns}:{field}:{docId} →  present (key existence = truncation occurred)
```

**Vector entry** stores the SQ8-quantized embedding for a single
`(document, field)` pair. At 384 bytes per entry (one byte per dimension) this
is a 4× reduction from float32 (1,536 bytes), with negligible accuracy loss for
cosine similarity ranking (see SQ8 Quantization below).

**Corpus stats** maintains the count of indexed documents (`n`) for index
metadata and state reporting. Unlike the lexical index, no `totalTokens`
equivalent is needed — cosine similarity scoring requires only the stored vectors
and the query vector.

**Truncation marker** is written only when a field value exceeded the 510-token
limit and was truncated before embedding. The key's presence is sufficient; the
value is empty. This is a diagnostic entry only and is not read on the query
path.

#### SQ8 Quantization

BGE Small En v1.5 outputs L2-normalized vectors — each vector has unit length,
so individual dimension values lie within $[-1, 1]$. This fixed, known range
makes quantization straightforward without per-vector or per-dimension
calibration:

- **Encode:** $u = \text{clamp}(\text{round}((f + 1.0) / 2.0 \times 255), 0, 255)$
- **Decode:** $f = u / 255.0 \times 2.0 - 1.0$

No calibration metadata (per-dimension min/max) needs to be stored. If a future
model produces non-normalized outputs, per-dimension calibration can be added to
`$vec:corpus:` at that point.

#### Query behaviour

At kmdb's expected scale (<50k documents), a brute-force flat scan is faster and
more battery-efficient than maintaining a graph-based index (HNSW etc.):

1. Embed the query string using the same pipeline as indexing (word segmentation
   → WordPiece → ONNX → mean pool → normalize → truncate at 510 tokens).
2. Prefix scan `$vec:{ns}:{field}:` to retrieve all `(docId, Uint8List)` pairs.
3. Dequantize each stored vector to float32.
4. Compute the dot product of each document vector with the query vector. Because
   both are L2-normalized, dot product equals cosine similarity.
5. Rank by score descending; return the top-`--candidates` results for RRF (or
   top-`--limit` directly for semantic-only queries).

### Open design questions

Many questions that arise in this design are also applicable to the
[Lexical Search](lexical_search.md) sub-proposal and are answered in that
document.

#### Q: How are inserts, updates and deletes handled?

Each document write must update the index. Modifications that include the
indexed field as well as the deletion of documents present the need to update
the index.

##### A: Direct overwrite — no overlay needed

Each `(docId, field)` maps to exactly one vector, so there are no stale term
entries and no overlay is required. The base index + overlay pattern from
[Lexical Search](lexical_search.md) does not apply here.

All writes are included in the same `WriteBatch` as the document write, making
them atomic. ONNX inference runs synchronously before the batch is committed —
the same pattern as lexical tokenization.

- **Insert:** run inference on the new field value; quantize the result to SQ8.
  In the WriteBatch: `PUT $vec:{ns}:{field}:{docId}` → quantized vector; if the
  value was truncated `PUT $vec:truncated:{ns}:{field}:{docId}` → empty;
  increment `n` in `$vec:corpus:{ns}:{field}`.

- **Update:** run inference on the new field value; quantize the result. In the
  WriteBatch: `PUT $vec:{ns}:{field}:{docId}` → new quantized vector (atomically
  replacing the old one); `DELETE $vec:truncated:{ns}:{field}:{docId}` (safe
  no-op if the key is absent, removes the marker if the new value no longer
  truncates, and is superseded by the subsequent `PUT` if it still does); if the
  new value was truncated `PUT $vec:truncated:{ns}:{field}:{docId}` → empty. `n`
  is unchanged.

- **Delete:** no inference needed. In the WriteBatch: `DELETE
  $vec:{ns}:{field}:{docId}`; `DELETE $vec:truncated:{ns}:{field}:{docId}`
  (safe no-op if absent); decrement `n` in `$vec:corpus:{ns}:{field}`.

##### Inference failure

If ONNX inference fails before the WriteBatch is committed, the entire operation
is rejected — the document write does not proceed. This keeps the document store
and the semantic index always consistent: a document either has a vector entry or
it was never written.

Inference failures indicate a systemic problem (model not loaded, out of memory)
rather than a data error. At kmdb's expected scale, inference on BGE Small is
fast and failures are rare; failing the write is the correct response.

A future enhancement (Option B) would write the document and mark it as pending
indexing, deferring inference to the next index build. This aligns with the
index lifecycle states from the secondary index design and is the right approach
once lazy build and background repair paths are in place.

## CLI

#### Index management

The `index` command described in the Lexical Search proposal will be also
utilised for create semantic search indexes. The addition to the approach
described there is the addition of a `--semantic` flag for the sub-commands.

```
kmdb <db> search list <collection> [--semantic]
kmdb <db> search create <collection> <field> [--lazy] [--semantic]
kmdb <db> search info <collection> <field> [--semantic]
kmdb <db> search delete <collection> <field> [--semantic]
kmdb <db> search build <collection> <field> [--force] [--semantic]
```

If the `--semantic` flag is provided, a semantic search index will be
created/built/deleted/described (info). The `list` command with the `--semantic`
flag will list the semantic search indexes in the collection.

The lexical search is the default approach so no flag is required to select it.

## API
