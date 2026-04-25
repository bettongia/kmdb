# Lexical Search

## Purpose

The lexical search index enables BM25 keyword search over nominated `String`
fields. It is an inverted index stored in the KV store under `$fts:` system
namespaces and maintained by the Query Layer with the same `WriteBatch`
atomicity guarantee as secondary indexes (§16).

## Text Preprocessing Pipeline

Every field value is processed through a four-stage pipeline before indexing.
The same pipeline is applied to query strings at search time.

### Stage 1 — Tokenisation

The field value is segmented into word tokens using a `Tokenizer`
implementation. Two implementations are provided:

| Implementation    | Approach                        | Default |
| :---------------- | :------------------------------ | :------ |
| `RegExpTokenizer` | Pure Dart, Unicode `\p{L}\p{N}` | Yes     |
| `IcuTokenizer`    | ICU C FFI, UAX #29              | No      |

`RegExpTokenizer` produces equivalent output to `IcuTokenizer` for English prose
and common technical identifiers (`mTLS`, `0x8004210B`). `IcuTokenizer` is
available as a drop-in substitute where full UAX #29 compliance is required; ICU
is a system library on all target platforms and requires no bundling.

The `Tokenizer` interface is intentionally narrow — a single `tokenise(String)`
method — so implementations can be swapped without touching the indexing
pipeline.

### Stage 2 — Normalisation

All tokens are lowercased using Unicode case folding so that a search for
`jekyll` matches `Jekyll`. Normalisation is applied uniformly to both indexed
values and query strings.

### Stage 3 — Stop-word filtering

Disabled by default. All tokens pass through unchanged. A pre-defined English
stop-word list (Stopwords ISO `en`) is available and can be opted into at index
creation time via the `stopWords: true` field on `FtsIndexDefinition` (Dart API)
or the `--stopwords` flag on `kmdb search create` (CLI). When enabled,
high-frequency low-information words (`the`, `and`, `is`) are removed before
stemming.

### Stage 4 — Stemming

Words are reduced to their base form using the Snowball algorithm
(`snowball_stemmer` Dart package) so that a search for `investigating` finds
`investigate`.

Examples: `investigates` → `investig`, `occurring` → `occur`, `disturbing` →
`disturb`.

## Index Structure

Four namespace types are written to the KV store, all exempt from the session
object cache and materialised view cache (§15). Because the KvStore enforces
32-char hex (UUIDv7) keys, compound `{term}:{docId}` keys are not possible. The
solution mirrors the secondary index design: each term gets its own namespace,
with document IDs as keys within it.

Terms are hex-encoded from their UTF-8 byte representation
(`utf8.encode(term).map(toHex).join()`), satisfying the KvStore namespace naming
constraint.

| Namespace                     | Key                        | Value                                  |
| :---------------------------- | :------------------------- | :------------------------------------- |
| `$fts:{ns}:{field}:{hexTerm}` | `{docId}` (32-char hex)    | CBOR int — term frequency (tf)         |
| `$fts:overlay:{ns}:{field}`   | `{docId}` (32-char hex)    | CBOR map (term→tf) \| TOMBSTONE string |
| `$fts:corpus:{ns}:{field}`    | fixed 32-char hex sentinel | CBOR map `{n, totalTokens}`            |
| `$fts:doc:{ns}:{field}`       | `{docId}` (32-char hex)    | CBOR map `{n: tokenCount, t: [terms]}` |

**Base index** — one entry per `(term, document)` pair. The namespace encodes
the hex term; the key is the document ID. The value is the term frequency (tf):
the number of times the stemmed term appears in the indexed field value.
Required for BM25 scoring.

**Overlay** — the authoritative state for documents modified since the last
compaction. Stores the current `term → tf` map for updated documents, or a
`TOMBSTONE` sentinel for deleted documents. Query time filters base index
results through the overlay to ensure correctness without a read-before-write on
the write path.

**Corpus stats** — maintained across all writes. `n` is the total number of
indexed documents; `totalTokens` is the sum of all document token counts.
`avgdl = totalTokens / n` is derived at query time for BM25 scoring. A single
entry is stored per `(ns, field)` under a fixed sentinel key
(`01900000000070009000000000000000`), which is safe because UUIDv7 keys begin
with a 48-bit millisecond timestamp and never collide with this all-zero-prefix
value.

**Per-doc forward index** — the token count and the list of indexed terms for
the most recently indexed value for each document. The token count is read once
on update and delete to adjust `totalTokens` in the corpus stats (the only
read-before-write in the design). The terms list is used during compaction to
enumerate the per-term namespaces that need stale entries removed.

## Write Behaviour

All index writes are included in the same `WriteBatch` as the document write,
making them atomic. WAL provides crash recovery with no additional work (§7).

This guarantee applies to the **write interception path** — individual insert,
update, and delete operations that arrive after the index is in place. It does
not extend to the **initial bulk build** (the scan of existing documents that
runs at first `search()` when `lazy: false`). The bulk build processes documents
sequentially across multiple batches; a crash mid-build leaves the index in the
`building` lifecycle state, which is detected and re-triggered at the next
`open()`.

### Insert

1. Tokenise, normalise, and stem the field value.
2. In the `WriteBatch`:
   - `PUT $fts:{ns}:{field}:{hexTerm}` / key=`{docId}` → tf, for each unique
     term.
   - `PUT $fts:doc:{ns}:{field}` / key=`{docId}` →
     `{n: tokenCount, t: [terms]}`.
   - Increment `n` and add token count to `totalTokens` in corpus stats.

No overlay entry is written on insert — there is no prior state to invalidate.

### Update

1. Read `$fts:doc:{ns}:{field}` / key=`{docId}` to obtain the old token count
   (one targeted read, outside the batch).
2. Tokenise, normalise, and stem the new field value.
3. In the `WriteBatch`:
   - `PUT $fts:{ns}:{field}:{hexTerm}` / key=`{docId}` → tf, for each term in
     the new value (additive — stale entries in old per-term namespaces are left
     in place for compaction).
   - `PUT $fts:overlay:{ns}:{field}` / key=`{docId}` → new `term → tf` map.
   - `PUT $fts:doc:{ns}:{field}` / key=`{docId}` → updated `{n, t}` map (retains
     old terms list so compaction can enumerate stale namespaces).
   - Adjust `totalTokens` by `newCount − oldCount` in corpus stats. `n` is
     unchanged.

### Delete

1. Read `$fts:doc:{ns}:{field}` / key=`{docId}` to obtain the old token count.
2. In the `WriteBatch`:
   - `PUT $fts:overlay:{ns}:{field}` / key=`{docId}` → TOMBSTONE.
   - `DELETE $fts:doc:{ns}:{field}` / key=`{docId}`.
   - Decrement `n` and subtract old token count from `totalTokens` in corpus
     stats.

Stale base index keys are left in place and cleaned up at compaction.

## Query Behaviour

1. If a `filter` was provided, resolve the set of matching docIds using
   secondary indexes (§16) if available, or a full namespace scan with in-memory
   filter evaluation otherwise. This produces a `candidateIds` set used to
   restrict all subsequent steps.
2. For each query term (after the same tokenise → normalise → stem pipeline): a.
   Scan the per-term namespace `$fts:{ns}:{field}:{hexTerm}` to collect
   `(docId, tf)` pairs (all keys in the namespace are docIds), restricting to
   `candidateIds` when present. b. Filter each result through the overlay
   (`$fts:overlay:{ns}:{field}`):
   - No overlay entry → trust the base index tf.
   - Overlay entry present → include only if the term appears in the overlay
     map; use the overlay tf (supersedes the base index value).
   - TOMBSTONE present → exclude unconditionally.
3. `df` for the term is the count of surviving results — derived from the scan,
   not stored separately.
4. Read corpus stats from `$fts:corpus:{ns}:{field}` once per query to obtain
   `n` and `totalTokens`. Compute `avgdl = totalTokens / n`.
5. Score each surviving candidate using BM25 (see Ranking Algorithm).
6. When multiple fields are searched, take the highest per-field score as the
   document's overall score. Per-field scores are carried in
   `SearchHit.fieldScores`.
7. Apply `limit` and `offset` to the ranked results.

## Ranking Algorithm — BM25

$$\text{BM25}(D, Q) = \sum_{i=1}^{n} \text{IDF}(q_i) \cdot \frac{f(q_i, D) \cdot (k_1 + 1)}{f(q_i, D) + k_1 \cdot \left(1 - b + b \cdot \frac{|D|}{\text{avgdl}}\right)}$$

| Symbol         | Meaning                                          | Default |
| :------------- | :----------------------------------------------- | :------ |
| $f(q_i, D)$    | Term frequency of query term $i$ in document $D$ | —       |
| $\|D\|$        | Token count of document $D$                      | —       |
| $\text{avgdl}$ | Average token count across all indexed documents | —       |
| $k_1$          | Term frequency saturation constant               | 1.2     |
| $b$            | Length normalisation constant                    | 0.75    |

$k_1$ and $b$ are configurable per index at creation time.

## Compaction

Compaction reconciles the overlay with the base index, removing stale entries.
Each document in the overlay is processed as a single atomic `WriteBatch`.

The per-doc forward index (`$fts:doc:{ns}:{field}`) stores the terms list from
the _previous_ write, which lets compaction enumerate all per-term namespaces
that may hold stale entries for the document.

**Live overlay entry** (term → tf map):

```
WriteBatch:
  DELETE $fts:{ns}:{field}:{hexStale}  / key={docId}  ← terms absent from overlay map
  PUT    $fts:{ns}:{field}:{hexLive}   / key={docId}  ← update tf if changed
  DELETE $fts:overlay:{ns}:{field}     / key={docId}
  PUT    $fts:doc:{ns}:{field}         / key={docId}  ← update terms list to live set
```

**Tombstone entry**:

```
WriteBatch:
  DELETE $fts:{ns}:{field}:{hexTerm}   / key={docId}  ← for every term in doc forward index
  DELETE $fts:doc:{ns}:{field}         / key={docId}
  DELETE $fts:overlay:{ns}:{field}     / key={docId}
```

Because all removals and the overlay clearance are in the same `WriteBatch`, a
crash mid-compaction leaves each document in one of two safe states:

- **Overlay still present** — queries continue filtering correctly; next
  compaction cycle reprocesses the entry.
- **Overlay and stale entries both gone** — index is fully clean for this
  document.

The unsafe state — overlay cleared but stale entries remaining — cannot occur.

## Cache Exemption

All `$fts:` system namespaces are exempt from the session object cache and the
materialised view cache. FTS index data does not pass through these caches and
therefore does not trigger namespace generation counter churn on document
writes.

## Post-Sync Delta Rebuild

When documents arrive via sync, `FtsManager` receives a `SyncDelta` event
carrying the `(docId, changeType)` pairs for the namespace (§20.8). Processing
is identical to write interception with one difference: the delta is applied as
a catch-up batch outside any document `WriteBatch`.

For each entry in the delta:

- **Added / updated** — fetch the current document value from the KV store, run
  the preprocessing pipeline (tokenise → normalise → [stop-word filter] → stem),
  and write FTS entries using the same overlay-based update path as §21 Write
  Behaviour.
- **Deleted** — write a TOMBSTONE to `$fts:overlay:{ns}:{field}` / key=`{docId}`
  and update corpus stats, identical to the delete path in §21 Write Behaviour.

Each document in the delta is committed in its own `WriteBatch` for crash
safety. If the process is killed mid-delta, the `syncing` → `stale` transition
on next `open()` (§20.8) ensures a full rebuild cleans up any partial state.

FTS tokenisation is fast enough that even a first-load delta of several thousand
documents completes in well under a second on any supported device.
