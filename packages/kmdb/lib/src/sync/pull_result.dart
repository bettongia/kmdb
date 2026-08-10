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

/// @docImport 'sync_engine.dart';
/// @docImport 'sync_result.dart';
/// @docImport '../engine/kvstore/kv_store.dart';
library;

import '../engine/kvstore/quarantine.dart';
import '../engine/util/hlc.dart';

/// A peer SSTable that `SyncEngine.pull` skipped **transiently** because its
/// `maxHlc` is at or below the local tombstone GC floor
/// (`StaleSstableIngestException`, H4-FU3).
///
/// This is structurally distinct from [QuarantinedSstable] — a deliberate
/// type-level separation (finding A3, Q2) rather than reusing
/// [QuarantinedSstable] with a different reason:
///
/// - **Not persisted.** Unlike a quarantine, this file is *not* permanently
///   dropped: the peer high-water mark is left untouched, so the file is
///   reconsidered on every subsequent [SyncEngine.pull] until it either
///   ingests successfully (e.g. after a consolidation replaces it with
///   post-floor output) or the local floor advances past it. Persisting a
///   record that describes a self-resolving, retried-forever condition would
///   be actively misleading — the durable `$$quarantine` log exists
///   specifically to survive a *permanent* decision surviving a missed pull
///   result, which does not apply here.
/// - **No [QuarantineReason].** The reason is always the same
///   (sub-floor `maxHlc`) and is not one of the five exception types
///   [QuarantineReason] enumerates.
///
/// See `StaleSstableIngestException`'s doc comment for the full mechanism.
final class DeferredSstable {
  /// Creates a [DeferredSstable] record.
  const DeferredSstable({
    required this.peerDeviceId,
    required this.filename,
    required this.maxHlc,
    required this.floor,
  });

  /// The 8-character hex device ID of the peer that produced the deferred
  /// file, parsed from [filename].
  final String peerDeviceId;

  /// The bare SSTable filename that was deferred.
  final String filename;

  /// The file's `maxHlc`, parsed from [filename].
  final Hlc maxHlc;

  /// The local tombstone GC floor at the time of the check. [maxHlc] is at or
  /// below this value, which is why the file was deferred rather than
  /// ingested.
  final Hlc floor;
}

/// The outcome of a single [SyncEngine.pull] call.
///
/// Reports every peer SSTable that was permanently [quarantined] (dropped and
/// never re-fetched — also durably logged, see `MetaStore.appendQuarantine`)
/// or transiently [deferred] (skipped this cycle, retried automatically) by
/// this pull. Both lists are pure observations of the same ingest loop that
/// decides HWM advancement — building this result never reorders or gates
/// that decision (see `SyncEngine.pull`'s crash-safety ordering note).
///
/// ## Cancellation contract
///
/// If the pull is cancelled mid-flight (`SyncCancelledException`), no
/// [PullResult] is returned at all — the exception propagates uncaught and
/// any [quarantined]/[deferred] entries accumulated so far are discarded by
/// the caller along with everything else on the stack. There is no partial
/// result on cancellation. Quarantine records already durably logged before
/// the cancellation are **not** rolled back — they were already true and
/// permanent by the time they were written (see the ordering note); only the
/// *report* of that pull's activity is lost, not the underlying log entries,
/// which remain queryable via `KmdbDatabase.quarantinedSstables`.
final class PullResult {
  /// Creates a [PullResult].
  const PullResult({this.quarantined = const [], this.deferred = const []});

  /// Peer SSTables permanently quarantined during this pull.
  final List<QuarantinedSstable> quarantined;

  /// Peer SSTables transiently deferred during this pull (sub-floor
  /// `maxHlc`, retried automatically on a later pull).
  final List<DeferredSstable> deferred;
}
