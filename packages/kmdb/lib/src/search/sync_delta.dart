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

/// The type of change in a [SyncDelta] entry.
///
/// Emitted by the sync engine after SSTable ingestion to describe what
/// happened to each document in the affected namespace.
enum DeltaChangeType {
  /// A document was added by a remote device and is not present locally.
  added,

  /// A document was updated by a remote device (the local copy was
  /// overwritten by the remote version via LWW).
  updated,

  /// A document was deleted by a remote device.
  deleted,
}

/// Describes the set of document changes in a single namespace that arrived
/// as part of a sync pull (spec §20.8).
///
/// The sync engine emits one [SyncDelta] per affected namespace after
/// ingesting remote SSTables. [FtsManager] and [VecManager] consume deltas
/// to keep their indexes up to date without a full rebuild.
///
/// ## Example
///
/// ```dart
/// final delta = SyncDelta(
///   namespace: 'articles',
///   changes: [
///     (docId: 'abc123', changeType: DeltaChangeType.added),
///     (docId: 'def456', changeType: DeltaChangeType.deleted),
///   ],
/// );
/// await ftsManager.applyDelta('articles', delta);
/// ```
final class SyncDelta {
  /// Creates a [SyncDelta].
  const SyncDelta({required this.namespace, required this.changes});

  /// The collection namespace that was affected by the sync pull.
  final String namespace;

  /// The list of document changes in this namespace.
  ///
  /// Each entry names the document key ([DeltaEntry.docId]) and the type of
  /// change ([DeltaEntry.changeType]).
  final List<DeltaEntry> changes;
}

/// A single document change within a [SyncDelta].
typedef DeltaEntry = ({String docId, DeltaChangeType changeType});
