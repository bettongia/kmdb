# Glossary

`$$` (double-dollar prefix)

: The local-only namespace prefix. Any namespace whose name starts with `$$`
  contains device-local derived data that is **never uploaded to the sync
  folder**. The three built-in local-only namespace classes are `$$fts:*`
  (BM25 inverted-index entries), `$$vec:*` (SQ8-quantized embedding vectors),
  and `$$index:*` (secondary index entries). At flush time, entries in
  `$$`-prefixed namespaces are written to a `.local.sst` file; `SyncEngine.push`
  identifies and skips these files by parsing the filename suffix. See §6, §8,
  §12. Implemented by `isLocalOnly`.

`isLocalOnly`

: A free function in `namespace_codec.dart` that returns `true` when a namespace
  starts with `$$`. The single source of truth for the local-only predicate;
  used at flush time (memtable partitioning in `LsmEngine`), at compaction time
  (writer routing and `LocalOnlyCollapsePolicy` resolution in `CompactionJob`),
  and implicitly at sync time (via the `.local.sst` filename suffix). See `$$`.

avgdl

: Average document length (token count) across all documents in the indexed
  collection. Computed as `totalTokens / n` at query time from corpus stats
  stored in `$$fts:corpus:{ns}:{field}`. Used in the BM25 denominator for
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

CancellationToken

: An imperative cancellation signal used to interrupt a sync run. Created by
  the caller and passed to `KmdbDatabase.sync/push/pull` via the `cancel`
  parameter. Backed by a `Completer<void>.sync()` so adapters can either poll
  `isCancelled` at I/O boundaries or race `whenCancelled` inside a
  `Future.any()` to wake immediately from a back-off sleep. See §12 —
  Cancellation and Timeout.

Argon2id

: A memory-hard key derivation function (KDF) combining the data-independent
  Argon2i and data-dependent Argon2d passes. Used in KMDB to derive a Key
  Encryption Key (KEK) from a user passphrase. Parameters (stored in `enc:blob`):
  m = 64 MiB, t = 3 rounds, p = 1 lane. The memory-hardness makes brute-force
  attacks prohibitively expensive. See §31.

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
  counts). Stored under `$$fts:corpus:{ns}:{field}`. Used to compute `avgdl`
  at query time and `IDF` in BM25 scoring.

CRC32C

: A variant of the CRC32 checksum using the Castagnoli polynomial. Used by
  the vault (§24) as a secondary identity discriminator (the ISS pattern's
  secondary hash). If two files share the same SHA-256 and byte count but
  differ in CRC32C, they are treated as distinct objects and the incoming
  file is rejected.

DEK (Data Encryption Key)

: A 256-bit random key used to encrypt and decrypt all document values in an
  encrypted KMDB database. Generated once at provisioning time and stored only
  in wrapped (encrypted) form inside `enc:blob`. The DEK never leaves process
  memory in plaintext; it is held in a `DekCache` for the duration of the
  session. See §31.

DekCache

: A session-scoped cache for the decrypted DEK, so Argon2id is only run once
  per `KmdbDatabase.open()`. The default `InMemoryDekCache` stores the DEK in
  process memory. The `FlutterSecureDekCache` from the `kmdb_flutter` add-on
  stores it in iOS Keychain / Android Keystore. See §31.

Embedding

: A dense vector representation of a text string produced by a neural language
  model — BGE Small En v1.5 (English-only) or `multilingual-e5-small`
  (~100 languages) in KMDB. Captures semantic meaning — similar concepts
  produce similar vectors, enabling cosine similarity search. Both currently
  registered models are 384-dimensional; embeddings are quantized to SQ8 for
  storage. See §22.

EmbeddingKind

: An enum (`document` / `query`) passed to `EmbeddingModel.embed()` to select
  which of a model's `queryPrefix`/`documentPrefix` (if any) to prepend before
  embedding. `multilingual-e5-small` requires a mandatory `"passage: "` /
  `"query: "` prefix distinguishing indexed text from query text; BGE Small
  En v1.5 defines neither prefix, so `EmbeddingKind` is a no-op for it. See
  §22.

enc:blob

: A CBOR-encoded record stored in the `$meta` namespace under the key `enc:blob`.
  Contains the Argon2id salt, Argon2id parameters, and the DEK wrapped under
  two KEKs (passphrase-derived and recovery-derived). Written at provisioning
  time and read at every encrypted database open. Absent in plaintext databases.
  See §31.

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
  (`$$fts:{ns}:{field}:{hexTerm}`), with document IDs as keys and term
  frequency as values.

ISS pattern (Identity–Size–Secondary)

: A collision-resistance technique used by the vault. The primary identity is
  SHA-256; the exact byte count is the secondary filter; CRC32C is the
  tertiary discriminator. An incoming blob must match all three before it is
  accepted as a duplicate of an existing vault object.

KEK (Key Encryption Key)

: A 256-bit key used to wrap (encrypt) the DEK. KMDB derives two KEKs:
  one from the user's passphrase via Argon2id, and one from a random recovery
  entropy via HKDF-SHA256. Both wrapped DEK copies are stored in `enc:blob`.
  See §31.

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

: A per-`(namespace, field)` KV namespace (`$$fts:overlay:{ns}:{field}`) that
  stores the authoritative current term→tf map (or TOMBSTONE) for documents
  that have been updated or deleted since the last FTS compaction. Query time
  filters base index results through the overlay for correctness. See §21.

Pin (vault)

: A device-local entry in the `VAULT_OFFLINE` flat file that signals "keep
  this blob downloaded on this device." Pins do not affect the GC lifecycle;
  a pinned object with zero references is still tombstoned and deleted. See §24.

Recovery code

: A 16-word mnemonic encoding 128 bits of entropy, used as an alternative
  credential to unlock an encrypted KMDB database. Generated once at
  provisioning time and shown to the user exactly once — it is not stored
  anywhere in the database. Uses a fixed 256-word wordlist (one word per byte
  value). Decode is case-insensitive and whitespace-tolerant. See §31.

RRF (Reciprocal Rank Fusion)

: The re-ranking algorithm used by hybrid search (§23). Combines the BM25
  ranked list and the cosine similarity ranked list without requiring score
  normalisation. Each document's RRF score is
  `Σ_{r} 1 / (k + rank_r(d))`, where `k = 60` (smoothing constant from the
  original paper, configurable) and `rank_r(d)` is the document's 1-based
  position in list `r`.

SyncCancelledException

: The exception thrown by `SyncContext.throwIfExpired()` — and by cloud
  adapter implementations — when a sync run is cancelled or its deadline is
  exceeded. Implements `Exception`. The `message` field distinguishes
  user-initiated cancels (`'Sync cancelled'`) from timeouts
  (`'Sync deadline exceeded'`). See §12 — Cancellation and Timeout.

SyncContext

: An immutable, per-sync-run carrier object threading `CancellationToken` and
  an absolute `deadline` through every `SyncStorageAdapter` call. Constructed
  once at `KmdbDatabase.sync/push/pull` from the caller's `cancel` and
  `timeout` parameters. Adapters call `ctx?.throwIfExpired()` at I/O
  boundaries; it throws `SyncCancelledException` if either signal is active.
  See §12 — Cancellation and Timeout.

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

Wrapped DEK

: The DEK encrypted under a KEK using AES-256-GCM with a random nonce. Stored
  as `nonce(12B) || ciphertext || tag(16B)` in the `enc:blob` (one copy per
  KEK: passphrase-derived and recovery-derived). The term "wrapped" follows the
  NIST key wrapping convention. See §31.

VaultSearchConfig

: Configuration record passed to `KmdbDatabase.open(vaultSearch: ...)` to
  enable vault search. Parameters: `extractors` (list of `VaultTextExtractor`
  implementations, default empty — `PlainTextExtractor` is always available),
  `chunkSize` (target window size in words, default 300), and `chunkOverlap`
  (overlap between consecutive windows in words, default 50). See §32.

VaultSearchManager

: Internal orchestrator for the vault search lifecycle. Created by
  `KmdbDatabase.open()` when a `VaultSearchConfig` is provided. Manages the
  queue of blobs awaiting extraction, spawns the `VaultIndexingIsolate`,
  calls the embedding model on the main isolate, and coordinates writes to
  `VaultBm25Writer` and `VaultVecWriter`. Performs startup recovery for blobs
  stuck in the `extracting` state after a crash. Not part of the public API.
  See §32.

VaultTextExtractor

: A strategy interface for extracting plain UTF-8 text from a vault blob of a
  specific media type. The built-in implementation is `PlainTextExtractor` for
  `text/plain` and `text/*` blobs; it uses charset detection (WI-2) to decode
  non-UTF-8 content. Custom extractors are registered via
  `VaultSearchConfig.extractors`. See §32.

`$vault:{sha256}`

: The per-blob system namespace holding a vault object's reference count,
  keyed by a single fixed sentinel (`kVaultRefCountSentinelKey`, a
  UUIDv7-shaped constant) rather than by the sha256 itself — every KV key,
  regardless of namespace, must pass `KeyCodec.keyToBytes`'s 32-char UUIDv7
  validation, which a 64-character SHA-256 hex digest cannot satisfy. This
  mirrors the `$vault:docref:{sha256}` and `$$vault:fts:corpus:{sha256}` /
  `$$vault:extract:{sha256}` sentinel-key patterns. Synced (single `$`
  prefix, unlike the local-only `$$vault:*` search namespaces below). See §24.

`$$vault:fts:`

: The `$$`-prefixed local-only namespace used to store BM25 inverted-index
  entries for vault blobs. Full form: `$$vault:fts:{sha256}:{hexTerm}` (per-chunk
  term frequency) and `$$vault:fts:corpus:{sha256}` (corpus statistics: chunk
  count and total token count). Never uploaded to the sync folder. See §32 and
  the `$$` (double-dollar prefix) entry.

`$$vault:vec:idx:`

: The `$$`-prefixed local-only namespace used to store SQ8-quantised embedding
  vectors for vault blob chunks. Full form: `$$vault:vec:idx:{sha256}:{chunkKey}`.
  One namespace per blob enables range-delete of all chunk vectors at GC time.
  Never uploaded to the sync folder. See §32.

chunk (vault)

: A fixed-size, overlapping window of words extracted from a vault blob during
  text indexing. Produced by `VaultChunker`. Default window size: 300 words
  with 50-word overlap. Each chunk carries its word offset and character offset
  into the original text, its token list (shared between BM25 and embedding),
  and its text content. Chunk windows prevent query terms that straddle a chunk
  boundary from being missed. See §32.

XXH64

: A non-cryptographic 64-bit hash function used for checksums throughout KMDB
  (SSTable blocks, Manifest records, WAL records). Chosen for its speed and
  low collision rate. See §9.
