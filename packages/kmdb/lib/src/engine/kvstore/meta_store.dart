// Copyright 2026 The Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:typed_data';

import 'package:cbor/cbor.dart';

import '../../encryption/encryption_blob.dart';
import '../../encryption/encryption_envelope.dart';
import '../../encryption/encryption_provider.dart';
import '../util/hlc.dart';
import '../util/xxhash.dart';
import 'kv_store.dart';
import 'lsm_engine.dart';

/// Access to the `$meta` system namespace.
///
/// Provides named helpers for the pieces of engine state stored in `$meta`:
///
/// - **Generation counters** (`gen:{namespace}`) — incremented on every write
///   to a user namespace. The Cache Layer reads these to detect stale cached
///   query results.
/// - **Dirty-open flag** (`dirty`) — written on the first user write after
///   open; cleared on clean close. If set on next open, it means the previous
///   session ended abruptly (crash or process kill), and secondary indexes may
///   need to be rebuilt.
/// - **Device identity** (`device_id`) — the stable 8-character lowercase hex
///   identifier used in SSTable filenames.
///
/// All writes go directly to [LsmEngine], bypassing the `$` namespace guard in
/// [KvStoreImpl] (which is intentional — these are internal writes). All
/// writes therefore go through the WAL as required by the spec.
///
/// ## Key encoding
///
/// Meta keys are symbolic names (e.g. `gen:tasks`, `dirty`). They are encoded
/// as deterministic 32-character hex strings via a two-seed XXH64 hash, which
/// matches the 16-byte key format the LSM engine requires. Collision probability
/// across the ~100 distinct names `$meta` will ever hold is negligible.
///
/// ## Encryption (Gap 3, Encryption confidentiality reconciliation plan)
///
/// `MetaStore` is constructed at the engine layer, below the point where
/// `KmdbDatabase.open()` derives the database's [EncryptionProvider] (the
/// bootstrap reads `enc:blob`, which must itself stay unencrypted — see
/// [getEncryptionBlob]). [encryption] is therefore a late-bound, mutable
/// field rather than a constructor parameter: `KmdbDatabase.open()` assigns
/// it immediately after the encryption bootstrap resolves and before
/// constructing any other collaborator, so every `$meta` write from that
/// point on (including the very first one) is encrypted when a provider is
/// configured. Every value below except [kEncryptionBlobName]
/// (`enc:blob`, exempt by design — see [getEncryptionBlob]/
/// [putEncryptionBlob]) and [kFormatVersionMarkerName] (exempt for the same
/// non-circularity reason — see [getFormatVersionMarker]) is wrapped with
/// [EncryptionEnvelope] before being written. None of these values are
/// `Map<String, dynamic>`-shaped (they are scalars, an `Hlc`, or opaque
/// state blobs from other collaborators), so [EncryptionEnvelope] applies
/// uniformly rather than `ValueCodec` (Phase 0/B7).
final class MetaStore {
  /// Creates a [MetaStore] that reads and writes through [engine].
  MetaStore(this._engine);

  final LsmEngine _engine;

  /// The database's [EncryptionProvider], or `null` for a plaintext
  /// database. Late-bound and mutable — see the class doc comment for why.
  EncryptionProvider? encryption;

  /// The system namespace for all meta values.
  static const String kNamespace = r'$meta';

  // ── Generation counters ──────────────────────────────────────────────────

  /// Returns the current generation counter for [userNamespace], or 0 if not
  /// yet set.
  ///
  /// The Cache Layer compares this value against a cached snapshot to decide
  /// whether to evict stale entries.
  Future<int> getGenerationCounter(String userNamespace) async {
    final bytes = await _engine.get(kNamespace, _genKey(userNamespace));
    if (bytes == null) return 0;
    final unwrapped = await EncryptionEnvelope.unwrap(bytes, encryption);
    if (unwrapped.length < 8) return 0;
    return ByteData.sublistView(unwrapped).getUint64(0, Endian.big);
  }

  /// Increments and persists the generation counter for [userNamespace].
  ///
  /// Called by [KvStoreImpl] after each successful user write. Returns the
  /// new counter value.
  ///
  /// This path issues a standalone `_engine.put` and should only be used
  /// where folding into a [WriteBatch] is not possible (e.g. the legacy
  /// single-`put`/`delete` path). Prefer [appendGenerationCounterBump] when
  /// building a [WriteBatch] so the counter increment is part of the same
  /// atomic WAL frame as the document write.
  Future<int> incrementGenerationCounter(String userNamespace) async {
    final current = await getGenerationCounter(userNamespace);
    final next = current + 1;
    final wrapped = await EncryptionEnvelope.wrap(
      _encodeUint64(next),
      encryption,
    );
    await _engine.put(kNamespace, _genKey(userNamespace), wrapped);
    return next;
  }

  /// Reads the current generation counter for [userNamespace] and appends
  /// a put of the incremented value to [batch].
  ///
  /// This is the batch-aware variant of [incrementGenerationCounter]. Use this
  /// when building a [WriteBatch] so the generation bump is written in the same
  /// atomic WAL frame as the documents and index entries — ensuring that a crash
  /// can never leave a document present without its corresponding generation
  /// bump (review finding H2, decision D2).
  ///
  /// Returns the new counter value (the value that will be written when [batch]
  /// is committed).
  ///
  /// Encrypts in place (per Phase 2/B3) — this method is already
  /// `Future`-returning with an internal read-modify-write, so wrapping the
  /// computed value before the `batch.put` call is a contained, mechanical
  /// addition with no `WriteBatch`-API ripple.
  Future<int> appendGenerationCounterBump(
    String userNamespace,
    WriteBatch batch,
  ) async {
    final current = await getGenerationCounter(userNamespace);
    final next = current + 1;
    final wrapped = await EncryptionEnvelope.wrap(
      _encodeUint64(next),
      encryption,
    );
    batch.put(kNamespace, _genKey(userNamespace), wrapped);
    return next;
  }

  /// Returns the `$meta` key for the generation counter of [userNamespace].
  ///
  /// Exposed for tests that need to verify the key exists directly.
  static String genKey(String userNamespace) => _genKey(userNamespace);

  static String _genKey(String userNamespace) =>
      _nameToKey('gen:$userNamespace');

  // ── Dirty-open flag ────────────────────────────────────────────────────────

  /// Returns `true` if the dirty-open flag is set in `$meta`.
  ///
  /// A set flag means the previous session did not call [close] cleanly —
  /// either the process was killed or the machine lost power after at least one
  /// write. Secondary indexes for any namespace written in that session may be
  /// stale.
  ///
  /// This is a **presence check only** — it deliberately does not unwrap the
  /// stored bytes through [EncryptionEnvelope]. [KvStoreImpl.open] calls this
  /// method before [encryption] can be assigned (`KmdbDatabase.open()`'s
  /// encryption bootstrap runs strictly after [KvStoreImpl.open] returns), so
  /// a dirty flag written by an *encrypted* previous session would otherwise
  /// be unreadable at exactly the point this method needs to read it. Since
  /// [setDirty] always writes a fixed sentinel and [clearDirty] deletes the
  /// key outright (never zeroes it), presence — encrypted or not — is
  /// sufficient to answer the question; no decryption is needed.
  Future<bool> getDirtyFlag() async {
    final bytes = await _engine.get(kNamespace, _nameToKey('dirty'));
    return bytes != null && bytes.isNotEmpty;
  }

  /// Writes the dirty-open flag to `$meta`.
  ///
  /// Called by [KvStoreImpl] on the first user write after open (§17, step 8).
  /// The flag is written lazily so read-only sessions never mark the database
  /// dirty. By the time any write reaches this method, `KmdbDatabase.open()`
  /// has already returned and [encryption] is assigned, so this write is
  /// always encrypted when a provider is configured.
  Future<void> setDirty() async {
    final wrapped = await EncryptionEnvelope.wrap(
      Uint8List.fromList([1]),
      encryption,
    );
    await _engine.put(kNamespace, _nameToKey('dirty'), wrapped);
  }

  /// Deletes the dirty-open flag. Called by [KvStoreImpl.close].
  Future<void> clearDirty() => _engine.delete(kNamespace, _nameToKey('dirty'));

  // ── Device ID ──────────────────────────────────────────────────────────────

  /// Returns the `$meta` key under which [device_id] is stored.
  ///
  /// Exposed for tests that need to read the raw (possibly encrypted) bytes
  /// directly — mirrors [genKey].
  static String get deviceIdKey => _nameToKey('device_id');

  /// Returns the stored 8-character device ID, or `null` if not yet set.
  Future<String?> getDeviceId() async {
    final bytes = await _engine.get(kNamespace, _nameToKey('device_id'));
    if (bytes == null) return null;
    final unwrapped = await EncryptionEnvelope.unwrap(bytes, encryption);
    return String.fromCharCodes(unwrapped);
  }

  /// Stores [deviceId] persistently in `$meta`.
  ///
  /// [deviceId] must be an 8-character lowercase hex string.
  Future<void> putDeviceId(String deviceId) async {
    final wrapped = await EncryptionEnvelope.wrap(
      Uint8List.fromList(deviceId.codeUnits),
      encryption,
    );
    await _engine.put(kNamespace, _nameToKey('device_id'), wrapped);
  }

  // ── Namespace registry ─────────────────────────────────────────────────────

  static const String _kNamespacesKey = 'namespaces';

  /// Returns the sorted list of user-visible namespaces that have been written
  /// to, as stored in `$meta`. Returns an empty list if none have been
  /// registered yet.
  ///
  /// The stored value is a CBOR **list** of strings, not a map, so it is
  /// wrapped with [EncryptionEnvelope] rather than `ValueCodec` (Phase 0/B7).
  Future<List<String>> getNamespaces() async {
    final bytes = await _engine.get(kNamespace, _nameToKey(_kNamespacesKey));
    if (bytes == null) return [];
    final unwrapped = await EncryptionEnvelope.unwrap(bytes, encryption);
    if (unwrapped.isEmpty) return [];
    final decoded = cbor.decode(unwrapped);
    if (decoded is! CborList) return [];
    return decoded
        .map((e) => e is CborString ? e.toString() : null)
        .whereType<String>()
        .toList()
      ..sort();
  }

  /// Adds [userNamespace] to the persisted set of known namespaces.
  ///
  /// This is called by [KvStoreImpl] after any successful user write. It is a
  /// no-op if the namespace is already registered, so the overhead is a single
  /// `get` + conditional `put` per write.
  ///
  /// Prefer [appendNamespaceRegistration] when building a [WriteBatch] so the
  /// registration is part of the same atomic WAL frame as the document write.
  Future<void> registerNamespace(String userNamespace) async {
    final current = await getNamespaces();
    if (current.contains(userNamespace)) return;
    final updated = [...current, userNamespace]..sort();
    final encoded = cbor.encode(CborList(updated.map(CborString.new).toList()));
    final wrapped = await EncryptionEnvelope.wrap(
      Uint8List.fromList(encoded),
      encryption,
    );
    await _engine.put(kNamespace, _nameToKey(_kNamespacesKey), wrapped);
  }

  /// Appends a namespace registration for [userNamespace] to [batch], if the
  /// namespace is not yet registered.
  ///
  /// This is the batch-aware variant of [registerNamespace]. Use this when
  /// building a [WriteBatch] so the registration is part of the same atomic
  /// WAL frame as the documents and index entries — ensuring that a crash can
  /// never leave a document present without its namespace being registered
  /// (review finding H2, decision D2).
  ///
  /// Returns `true` if a put was appended (the namespace was not already
  /// registered), `false` if the namespace was already present (no-op).
  ///
  /// Encrypts in place (per Phase 2/B3) — see [appendGenerationCounterBump]'s
  /// doc comment for the same rationale.
  Future<bool> appendNamespaceRegistration(
    String userNamespace,
    WriteBatch batch,
  ) async {
    final current = await getNamespaces();
    if (current.contains(userNamespace)) return false;
    final updated = [...current, userNamespace]..sort();
    final encoded = cbor.encode(CborList(updated.map(CborString.new).toList()));
    final wrapped = await EncryptionEnvelope.wrap(
      Uint8List.fromList(encoded),
      encryption,
    );
    batch.put(kNamespace, _nameToKey(_kNamespacesKey), wrapped);
    return true;
  }

  /// Appends the dirty-open flag write to [batch].
  ///
  /// This is the batch-aware variant of [setDirty]. Use this when building a
  /// [WriteBatch] so the dirty flag is set atomically with the first document
  /// write — ensuring that a crash during the very first write of a session
  /// leaves the dirty flag set (so the next open detects the interrupted
  /// session) rather than absent (which would hide the interrupted session).
  ///
  /// Converted to `Future<void>` (from a synchronous `void`) so the value can
  /// be encrypted in place (Phase 2/B3) — its sole caller (`KvStoreImpl`'s
  /// batch-build function) already sits in an `async` function awaiting
  /// sibling meta calls, so adding one more `await` is a contained,
  /// mechanical change with no `WriteBatch`-API ripple.
  Future<void> appendDirtyFlag(WriteBatch batch) async {
    final wrapped = await EncryptionEnvelope.wrap(
      Uint8List.fromList([1]),
      encryption,
    );
    batch.put(kNamespace, _nameToKey('dirty'), wrapped);
  }

  /// Removes [userNamespace] from the persisted set of known namespaces and
  /// deletes its generation counter from `$meta`.
  ///
  /// Called when a collection is deleted so it no longer appears in
  /// [getNamespaces]. This is a no-op if the namespace is not currently
  /// registered.
  ///
  /// Other namespaces are unaffected.
  Future<void> unregisterNamespace(String userNamespace) async {
    final current = await getNamespaces();
    if (!current.contains(userNamespace)) return; // already absent — no-op

    // Write the updated namespace list without [userNamespace].
    final updated = current.where((ns) => ns != userNamespace).toList()..sort();
    final encoded = cbor.encode(CborList(updated.map(CborString.new).toList()));
    final wrapped = await EncryptionEnvelope.wrap(
      Uint8List.fromList(encoded),
      encryption,
    );
    await _engine.put(kNamespace, _nameToKey(_kNamespacesKey), wrapped);

    // Remove the generation counter for this namespace.
    await _engine.delete(kNamespace, _genKey(userNamespace));
  }

  // ── Tombstone GC floor (H4-FU3; moved off `$meta` by 0.10.01 WI-11/Q-D) ────

  /// The local-only namespace holding the persisted tombstone GC floor.
  ///
  /// Moved out of synced `$meta` by the 0.10.01 WI-11 fix (Q-D): the floor is
  /// device-local *by design* (see [getTombstoneFloor]'s "Per-device by
  /// design" section below), but until this fix it was stored in synced
  /// `$meta` under the device-independent key `gc:tombstoneFloor`. `$meta`
  /// uses plain last-write-wins, not a max-merge, so a peer's *older* floor
  /// written with a *later* HLC could overwrite (and lower) this device's
  /// higher floor — re-enabling the exact tombstone-resurrection scenario the
  /// floor exists to prevent (see `IndexManager`'s sibling `$$indexstate`
  /// namespace for the identical device-local-state-in-a-synced-namespace
  /// defect shape). `$$gcstate` is local-only (see `isLocalOnly` in
  /// `namespace_codec.dart`), so it is never uploaded and a peer's floor can
  /// never affect this device's.
  static const String kGcStateNamespace = r'$$gcstate';

  /// Returns the persisted tombstone GC floor HLC, or `Hlc(0, 0)` if no
  /// compaction has ever dropped tombstones on this device.
  ///
  /// ## Semantics
  ///
  /// The floor is the highest `horizon` value that was passed to a
  /// [CompactionJob] that dropped at least one tombstone. It is a per-device
  /// monotonic value: it can only increase. The [LsmEngine] reads this value
  /// in [LsmEngine.ingestAt0] and rejects any incoming SSTable whose `maxHlc`
  /// satisfies `maxHlc <= floor`.
  ///
  /// ## Per-device by design
  ///
  /// The floor is stored in the local-only [kGcStateNamespace] namespace (see
  /// that constant's doc comment for why it moved out of `$meta`). Every
  /// device maintains its own floor independently. This is correct: the floor
  /// tracks the HLC range each device has GC'd locally, and that history is
  /// not transferable — another device may not have GC'd the same range and
  /// must not inherit a floor that overstates its own history.
  ///
  /// ## Consistency with local state
  ///
  /// The floor is valid against any consistent local state, including after a
  /// filesystem snapshot rollback: a rollback restores both the dropped
  /// tombstones (from the pre-GC SSTables) *and* the pre-GC floor (from the
  /// pre-GC [kGcStateNamespace] entry), leaving the engine in a coherent older
  /// state. The floor is never ahead of actual GC history.
  ///
  /// ## Default on fresh DB
  ///
  /// A freshly-opened database that has never run a tombstone-dropping
  /// compaction has no floor entry. This method returns `Hlc(0, 0)` in that
  /// case, which causes [LsmEngine.ingestAt0] to accept every incoming SSTable
  /// (no realistic SSTable has `maxHlc <= Hlc(0, 0)`).
  Future<Hlc> getTombstoneFloor() async {
    final bytes = await _engine.get(
      kGcStateNamespace,
      _nameToKey('gc:tombstoneFloor'),
    );
    if (bytes == null) return const Hlc(0, 0);
    final unwrapped = await EncryptionEnvelope.unwrap(bytes, encryption);
    if (unwrapped.length < 8) return const Hlc(0, 0);
    final encoded = ByteData.sublistView(unwrapped).getUint64(0, Endian.big);
    return Hlc.fromEncoded(encoded);
  }

  /// Persists [floor] as the new tombstone GC floor in the local-only
  /// [kGcStateNamespace] namespace.
  ///
  /// The floor is monotonic under correct operation: callers must only call
  /// this with a value greater than or equal to the current floor. A value
  /// equal to the current floor is a no-op in effect but still issues a write
  /// (idempotent under the WAL last-write-wins ordering).
  ///
  /// This is the standalone variant — issues a direct [LsmEngine.put]. Use
  /// [appendTombstoneFloorAdvance] when the write must be part of a
  /// [WriteBatch] for atomicity. Only this standalone variant is exercised in
  /// production (`LsmEngine._compactAll`/`KvStoreImpl.resetTombstoneFloor`
  /// call it directly) — see [appendTombstoneFloorAdvance]'s doc comment for
  /// why the batch-aware variant is intentionally left unencrypted (B3).
  Future<void> setTombstoneFloor(Hlc floor) async {
    final wrapped = await EncryptionEnvelope.wrap(
      _encodeUint64(floor.encoded),
      encryption,
    );
    await _engine.put(
      kGcStateNamespace,
      _nameToKey('gc:tombstoneFloor'),
      wrapped,
    );
  }

  /// Appends a tombstone floor advance write for [floor] to [batch].
  ///
  /// This is the batch-aware variant of [setTombstoneFloor]. Use this when
  /// building a [WriteBatch] so the floor advance is part of the same atomic
  /// WAL frame as other writes — useful for callers that want to fold the
  /// floor update into an existing batch for atomicity.
  ///
  /// Note that the Q6 atomicity decision for H4-FU3 chose option (b) — the
  /// floor write is a *separate* [kGcStateNamespace] put after the compaction
  /// manifest commits. This method is provided for completeness and future
  /// use; the [LsmEngine._compactAll] path calls [setTombstoneFloor] directly.
  ///
  /// **Left synchronous and unencrypted (Phase 2/B3 decision).** This method
  /// has no production call site today — `meta_store_test.dart` is its only
  /// caller. Wiring encryption into unused code would violate CLAUDE.md's
  /// "do not leave dead or unreachable code behind" principle in spirit; if
  /// this method gains a real caller, encrypt it then, following the same
  /// pattern as [setTombstoneFloor].
  ///
  /// **Read/write asymmetry warning:** because this method writes raw,
  /// unwrapped bytes while [getTombstoneFloor] now always unwraps through
  /// [EncryptionEnvelope], a value written by this method and later read via
  /// [getTombstoneFloor] on an encrypted database would misparse (the raw
  /// `Hlc`-encoded bytes have no leading [EncryptionFlag], so
  /// `EncryptionFlag.fromByte` would either throw or, in the unlucky case
  /// where the first byte happens to equal `0x00`/`0x01`, silently
  /// misinterpret it — the exact class of bug B9 exists to prevent
  /// elsewhere). If this method is ever wired up for real, it must call
  /// [EncryptionEnvelope.wrap] before `batch.put`, exactly as
  /// [setTombstoneFloor] does, not just have `encryption` added.
  void appendTombstoneFloorAdvance(Hlc floor, WriteBatch batch) {
    batch.put(
      kGcStateNamespace,
      _nameToKey('gc:tombstoneFloor'),
      _encodeUint64(floor.encoded),
    );
  }

  // ── Index state ────────────────────────────────────────────────────────────

  /// Returns the `$meta` key for the index state entry of [namespace]/[path].
  ///
  /// Exposed so the Query Layer can locate the raw bytes without going through
  /// the full index-state helpers when that is sufficient.
  static String indexKey(String namespace, String path) =>
      _nameToKey('index:$namespace:$path');

  /// Encodes an arbitrary symbolic name (e.g. `fts:tasks:title`,
  /// `vec:tasks:body`) using the same deterministic key scheme as every
  /// `$meta` entry.
  ///
  /// This exists so that state stores which used to live in `$meta` under a
  /// symbolic name — but were moved to a device-local `$$…state` namespace by
  /// the 0.10.01 WI-11 fix (secondary-index/FTS/Vec state; see
  /// `docs/spec/16_secondary_indexes.md`) — can keep computing their key with
  /// the exact same hash the rest of the codebase uses, without duplicating
  /// the encoding scheme. It is deliberately generic (unlike [indexKey],
  /// [genKey], [deviceIdKey]), because it is used for symbolic names this
  /// class does not otherwise know about. It does **not** read or write
  /// `$meta` itself — callers own the namespace, read/write, and encryption
  /// wrapping for wherever they store the resulting key.
  static String symbolicKey(String name) => _nameToKey(name);

  /// Reads the raw bytes stored under the symbolic [name] in `$meta`.
  ///
  /// Used by the Query Layer to persist and retrieve index state without
  /// accessing the engine's private fields directly. Every current consumer
  /// (`IndexManager`, `FtsIndexState`, `VecIndexState`, `SchemaManager`,
  /// `VersionManager`) stores an opaque state blob, so the value is wrapped
  /// with [EncryptionEnvelope] here (Phase 0/B7) — callers do not need to
  /// know or care whether encryption is active.
  ///
  /// **Not** used for [kEncryptionBlobName] (`enc:blob`) — see
  /// [getEncryptionBlob], which reads via [LsmEngine.get] directly instead,
  /// to keep the `enc:blob` bootstrap read genuinely raw and unaffected by
  /// this method's encryption wrapping (Q2).
  Future<Uint8List?> getRawByName(String name) async {
    final bytes = await _engine.get(kNamespace, _nameToKey(name));
    if (bytes == null) return null;
    return EncryptionEnvelope.unwrap(bytes, encryption);
  }

  /// Writes [bytes] under the symbolic [name] in `$meta`.
  ///
  /// Used by the Query Layer to persist index state atomically. See
  /// [getRawByName]'s doc comment for the encryption/`enc:blob` details.
  Future<void> putRawByName(String name, Uint8List bytes) async {
    final wrapped = await EncryptionEnvelope.wrap(bytes, encryption);
    await _engine.put(kNamespace, _nameToKey(name), wrapped);
  }

  /// Deletes the entry stored under the symbolic [name] in `$meta`.
  ///
  /// This is a no-op if [name] has never been written. Used by
  /// [IndexManager.removeIndex] to clear the persisted index state for a
  /// deleted index.
  Future<void> deleteRawByName(String name) =>
      _engine.delete(kNamespace, _nameToKey(name));

  // ── Encryption blob ─────────────────────────────────────────────────────────

  /// The symbolic name under which the encryption metadata blob is stored.
  static const String kEncryptionBlobName = 'enc:blob';

  /// Returns the `$meta` key under which `enc:blob` is stored.
  ///
  /// Exposed for tests that need to read the raw bytes directly and confirm
  /// they are never [EncryptionEnvelope]-wrapped (Q2) — mirrors [genKey]/
  /// [deviceIdKey].
  static String get encryptionBlobKey => _nameToKey(kEncryptionBlobName);

  /// Reads the [EncryptionBlob] from `$meta`, or `null` if it has not been
  /// written (i.e., the database is not encrypted).
  ///
  /// The blob is stored as raw CBOR — it is **not** routed through
  /// [ValueCodec] or [EncryptionEnvelope] — so that the bootstrap can read it
  /// before the DEK is available (non-circular by design). Reads via
  /// [LsmEngine.get] **directly**, bypassing [getRawByName] entirely (Q2):
  /// `getRawByName` now wraps its value with [EncryptionEnvelope] by
  /// default, so going through it here would break this exemption the
  /// moment a provider is configured. This direct-path fix keeps `enc:blob`
  /// on a genuinely separate raw path rather than depending on
  /// `getRawByName` staying unencrypted by accident.
  ///
  /// Throws [FormatException] if the stored bytes cannot be decoded.
  Future<EncryptionBlob?> getEncryptionBlob() async {
    final bytes = await _engine.get(
      kNamespace,
      _nameToKey(kEncryptionBlobName),
    );
    if (bytes == null) return null;
    return EncryptionBlob.decode(bytes);
  }

  /// Writes [blob] to `$meta` under `enc:blob`.
  ///
  /// The blob is encoded as raw CBOR and written via [LsmEngine.put]
  /// **directly** — it does NOT pass through [ValueCodec],
  /// [EncryptionEnvelope], or [putRawByName] — keeping the bootstrap
  /// non-circular (see [getEncryptionBlob]'s doc comment for the Q2
  /// direct-path rationale).
  ///
  /// This must be called (and fully flushed) **before** any encrypted user value
  /// is written, so that crash recovery can always find the blob when the engine
  /// is reopened.
  Future<void> putEncryptionBlob(EncryptionBlob blob) =>
      _engine.put(kNamespace, _nameToKey(kEncryptionBlobName), blob.encode());

  // ── Format-version marker (Phase 2/B8-B9) ─────────────────────────────────

  /// The symbolic name under which the `$meta` format-version marker is
  /// stored.
  static const String kFormatVersionMarkerName = 'formatVersion';

  /// The current database format version. Bumped whenever a future change
  /// alters the on-disk framing of `$meta`/index/FTS/Vec/vault values in a
  /// way that is not safely self-describing per value (mirroring the
  /// reasoning that motivated this marker in the first place — see the class
  /// doc comment and `docs/spec/31_encryption.md`).
  static const int kCurrentFormatVersion = 1;

  /// Reads the raw format-version marker byte, or `null` if absent.
  ///
  /// Reads via [LsmEngine.get] **directly**, the same raw path as
  /// [getEncryptionBlob] — this is the value `KvStoreImpl.open()` checks
  /// *before* any other `$meta`/index/FTS/Vec/vault value is read through
  /// [EncryptionEnvelope]/`ValueCodec`, so it must not itself depend on
  /// either (non-circular by construction, same reasoning as `enc:blob`).
  ///
  /// Absence does **not** by itself mean "legacy database" — see
  /// `KvStoreImpl.open()`'s three-way new/legacy/empty discrimination
  /// (Phase 2/B8-B9), which also consults [OpenResult.isNewDatabase].
  Future<int?> getFormatVersionMarker() async {
    final bytes = await _engine.get(
      kNamespace,
      _nameToKey(kFormatVersionMarkerName),
    );
    if (bytes == null || bytes.isEmpty) return null;
    return bytes[0];
  }

  /// Writes [kCurrentFormatVersion] as the format-version marker.
  ///
  /// Called exactly once, at initial database creation (`KvStoreImpl.open()`
  /// case (c) — see [getFormatVersionMarker]'s doc comment). Writes via the
  /// same raw path as [getFormatVersionMarker]/[getEncryptionBlob].
  Future<void> putFormatVersionMarker() => _engine.put(
    kNamespace,
    _nameToKey(kFormatVersionMarkerName),
    Uint8List.fromList([kCurrentFormatVersion]),
  );

  // ── Key encoding ───────────────────────────────────────────────────────────

  /// Encodes a symbolic [name] as a deterministic 32-character hex key.
  ///
  /// Two independent XXH64 digests (seeds 0 and 1) are concatenated to produce
  /// 16 bytes (32 hex chars). The resulting key is forced to follow the UUIDv7
  /// structural format (version 7, variant 2) to pass validation in the
  /// storage layer.
  static String _nameToKey(String name) {
    final data = Uint8List.fromList(name.codeUnits);
    final h1 = XxHash64.digest(data, seed: 0);
    final h2 = XxHash64.digest(data, seed: 1);
    final bytes = Uint8List(16);
    final bd = ByteData.sublistView(bytes);
    bd.setInt64(0, h1, Endian.big);
    bd.setInt64(8, h2, Endian.big);

    // Force UUIDv7 structural bits:
    // 1. Version 7: high nibble of byte 6 must be 0x7.
    bytes[6] = (bytes[6] & 0x0F) | 0x70;
    // 2. Variant 2: top two bits of byte 8 must be '10'.
    bytes[8] = (bytes[8] & 0x3F) | 0x80;

    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  // ── Value encoding ─────────────────────────────────────────────────────────

  /// Encodes [value] as a big-endian 8-byte unsigned integer.
  static Uint8List _encodeUint64(int value) {
    final bytes = Uint8List(8);
    // setUint64 writes 8 bytes treating value as unsigned; safe for generation
    // counters which are small positive integers.
    ByteData.sublistView(bytes).setUint64(0, value, Endian.big);
    return bytes;
  }
}
