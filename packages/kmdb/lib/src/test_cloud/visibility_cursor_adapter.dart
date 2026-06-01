// Copyright 2026 The Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

/// Optional interface for [SyncStorageAdapter] implementations that track a
/// per-observer visibility cursor.
///
/// Adapters backed by a [SharedCloudBackend] implement this interface to expose
/// the highest write-sequence number currently visible through this adapter
/// front-end. The [ReconciliationAgent] uses this value to restrict the
/// per-device expected-state merge to only the subset of peer writes that have
/// propagated to this device's adapter — the visibility model for eventual
/// consistency.
///
/// Strongly-consistent adapters ([SharedBackendAdapter]) return the backend's
/// current global maximum, so all committed writes are always visible. This
/// preserves backward-compatible behaviour: under strong consistency, the
/// [ReconciliationAgent] merges the full global state, identical to before.
///
/// The interface is checked via `is VisibilityCursorAdapter` at the
/// `PartitionableAdapter` boundary in [Device._sync]; adapters that do not
/// implement it (e.g. [MemorySyncAdapter], [LocalDirectoryAdapter]) produce
/// `null` for `visibleWriteSeqHigh` in [ActionResult], causing the
/// [ReconciliationAgent] to fall back to the legacy global-merge path.
abstract interface class VisibilityCursorAdapter {
  /// The highest write-sequence number that is currently visible through this
  /// adapter front-end.
  ///
  /// - For [SharedBackendAdapter]: always equals
  ///   `SharedCloudBackend.currentWriteSeq` (strong consistency — all writes
  ///   visible).
  /// - For [CloudSemanticsAdapter]: the current propagation-delay cursor, which
  ///   may lag behind the backend's maximum until
  ///   [CloudSemanticsAdapter.advancePropagationClock] is called.
  int get visibleWriteSeq;
}
