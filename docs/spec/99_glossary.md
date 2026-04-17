# Glossary

avgdl

: Average document length (token count) across all documents in the indexed
  collection. Computed as `totalTokens / n` at query time from corpus stats
  stored in `$fts:corpus:{ns}:{field}`. Used in the BM25 denominator for
  length normalisation.

BM25

: Best Match 25 — the probabilistic ranking function used by the lexical
  search index (§21). Scores a document against a query by combining
  per-term frequency (TF) with inverse document frequency (IDF) and a
  length normalisation factor. Parameters: `k₁ = 1.2`, `b = 0.75` (defaults;
  configurable per index). See §21 for the full formula.

Bloom filter

: A compact probabilistic bitset written into every SSTable (10 bits per key,
  ~0.8% false-positive rate). On a `get()` that misses, the Bloom filter lets
  the engine skip a file in microseconds rather than opening and scanning it.
  See §9.

CAS (Content-Addressable Storage)

: Storage model where objects are identified by a hash of their content rather
  than by an application-assigned name. The vault (§24) uses SHA-256 as the
  content address, providing automatic deduplication — two identical files
  share one vault object regardless of which document or collection references
  them.

Compaction

: The process of merging multiple SSTables to remove duplicate keys,
  tombstones, and level overlap, producing fewer, larger, non-overlapping
  files. KMDB compaction is synchronous on the write path. See §6.

Content-addressable storage

: See CAS.

Corpus stats

: Per-`(namespace, field)` statistics maintained by the FTS system: `n`
  (total indexed documents) and `totalTokens` (sum of all document token
  counts). Stored under `$fts:corpus:{ns}:{field}`. Used to compute `avgdl`
  at query time and `IDF` in BM25 scoring.

CRC32C

: A variant of the CRC32 checksum using the Castagnoli polynomial. Used by
  the vault (§24) as a secondary identity discriminator (the ISS pattern's
  secondary hash). If two files share the same SHA-256 and byte count but
  differ in CRC32C, they are treated as distinct objects and the incoming
  file is rejected.

Embedding

: A dense vector representation of a text string produced by a neural language
  model (BGE Small En v1.5 in KMDB). Captures semantic meaning — similar
  concepts produce similar vectors, enabling cosine similarity search. KMDB
  embeddings are 384-dimensional float32 vectors, quantized to SQ8 for
  storage. See §22.

Generation counter

: A monotonically increasing integer stored in `$meta` under `gen:{namespace}`,
  incremented on every `WriteBatch` that touches the namespace. The Cache
  Layer uses it for coarse namespace-level invalidation: if the counter has
  changed since an entry was cached, the whole namespace is considered stale
  and re-fetched. See §15.

HLC (Hybrid Logical Clock)

: A 64-bit timestamp combining a 48-bit physical component (millisecond
  wall-clock time) and a 16-bit logical counter. HLCs provide causally
  consistent ordering of events across devices without a central coordinator.
  KMDB uses HLC timestamps on WAL records and SSTable entries. See §4. See
  also:
  [Logical Physical Clocks and Consistent Snapshots in Globally Distributed Databases](https://cse.buffalo.edu/tech-reports/2014-04.pdf)

Hydration (vault)

: The process of downloading a vault blob from the sync folder to the local
  device. A stub (manifest present, blob absent) is *hydrated* when the user
  requests the file or pins it, by calling `VaultStorageAdapter.hydrateVaultBlob`.
  See §24.

IDF (Inverse Document Frequency)

: A component of BM25 that down-weights terms appearing in many documents
  (common terms like "the" contribute less signal). Computed as
  `log(1 + (n − df + 0.5) / (df + 0.5))` where `n` is the total document
  count and `df` is the number of documents containing the term.

Inverted index

: A data structure mapping from terms to the documents that contain them.
  KMDB's lexical search index (§21) stores one KV namespace per term
  (`$fts:{ns}:{field}:{hexTerm}`), with document IDs as keys and term
  frequency as values.

ISS pattern (Identity–Size–Secondary)

: A collision-resistance technique used by the vault. The primary identity is
  SHA-256; the exact byte count is the secondary filter; CRC32C is the
  tertiary discriminator. An incoming blob must match all three before it is
  accepted as a duplicate of an existing vault object.

KVLT

: The binary archive format used to package a document with its vault
  attachments for import/export/backup operations. Format:
  `[magic "KVLT"][version 4B][sequence of length-prefixed path+data entries][end marker]`,
  Zstandard-compressed. See §24.

LWW (Last-Write-Wins)

: KMDB's conflict resolution strategy. When two devices independently write to
  the same document key while offline, the version with the higher HLC
  timestamp is kept during compaction. If HLCs are identical, the device with
  the lexicographically higher `deviceId` wins as a tiebreaker. LWW operates
  at the document level. See §4 and §12.

Manifest (database)

: An append-only log (`MANIFEST-NNNNN`) recording which SSTables are live at
  which level. Each record is `[XXH64 8B][length 4B][CBOR VersionEdit]`. The
  `CURRENT` file names the active manifest. See §10.

Manifest (vault)

: A `manifest.json` file written alongside each vault blob, recording its
  SHA-256 hash, size, CRC32C, media type, original filename, and creation
  HLC. Immutable after creation. See §24.

Memtable

: An in-memory, sorted write buffer (backed by a skip list) that accumulates
  writes before flushing to an SSTable. Flushed when it exceeds 64 KB. See §6.

Overlay (FTS)

: A per-`(namespace, field)` KV namespace (`$fts:overlay:{ns}:{field}`) that
  stores the authoritative current term→tf map (or TOMBSTONE) for documents
  that have been updated or deleted since the last FTS compaction. Query time
  filters base index results through the overlay for correctness. See §21.

Pin (vault)

: A device-local entry in the `VAULT_OFFLINE` flat file that signals "keep
  this blob downloaded on this device." Pins do not affect the GC lifecycle;
  a pinned object with zero references is still tombstoned and deleted. See §24.

RRF (Reciprocal Rank Fusion)

: The re-ranking algorithm used by hybrid search (§23). Combines the BM25
  ranked list and the cosine similarity ranked list without requiring score
  normalisation. Each document's RRF score is
  `Σ_{r} 1 / (k + rank_r(d))`, where `k = 60` (smoothing constant from the
  original paper, configurable) and `rank_r(d)` is the document's 1-based
  position in list `r`.

SQ8 (Scalar Quantization, 8-bit)

: A vector compression technique that maps each float32 dimension value to a
  uint8. For L2-normalized vectors (range `[−1, 1]`) KMDB uses the formula
  `u = clamp(round((f + 1.0) / 2.0 × 255), 0, 255)`. Reduces storage from
  1,536 bytes to 384 bytes per 384-dimensional vector (4× reduction). See §22.

SSTable (Sorted String Table)

: An immutable file on disk storing sorted key-value pairs, a Bloom filter,
  an index block, and a footer with XXH64 checksums. The fundamental unit of
  both local storage and distributed sync. See §8.

Stemming

: Reducing words to their base form (stem) using the Snowball algorithm.
  Applied in Stage 4 of the FTS preprocessing pipeline (§21) so that a search
  for `investigating` matches documents containing `investigate`.

Stub (vault)

: A vault hash directory that contains `manifest.json` but no `blob` file.
  Indicates the object's metadata is known locally but the binary content has
  not been downloaded yet. Access via `VaultRef.getBlob()` triggers on-demand
  hydration. See §24.

Tombstone (LSM)

: A delete marker written to the LSM engine when a document is deleted.
  Suppresses older values for the same key during reads. Removed during
  compaction once all devices have seen the deletion. See §6.

Tombstone (vault)

: A `tombstone.json` file written in a vault hash directory when the object's
  reference count reaches zero. Its presence (not its content) signals that
  the object is a GC candidate. The GC sweep deletes the hash directory on
  its next pass, after re-validating that the ref count is still zero. See §24.

Vault

: KMDB's content-addressable binary object store. Provides file-attachment
  support for documents: files are stored outside the LSM engine, identified
  by SHA-256 hash, deduplicated across all documents and collections, and
  reference-counted for GC. Accessed via `VaultRef` in document models. See §24.

VaultRef

: A typed Dart wrapper around a `kmdb-vault://sha256/{64-hex}` URI. URI format
  is validated eagerly at construction. `getBlob()` and `getMetadata()` trigger
  on-demand hydration if the object is a stub. Equality is URI-based. See §24.

WAL (Write-Ahead Log)

: A sequential, append-only log that provides crash durability. Every write is
  fsynced to the WAL before updating the memtable — the WAL entry is the commit
  point. On recovery, WAL entries newer than the highest sequence number in the
  Manifest are replayed to restore the memtable to its pre-crash state. See §7.

XXH64

: A non-cryptographic 64-bit hash function used for checksums throughout KMDB
  (SSTable blocks, Manifest records, WAL records). Chosen for its speed and
  low collision rate. See §9.
