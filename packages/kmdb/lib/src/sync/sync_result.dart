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
library;

import 'pull_result.dart';

/// The outcome of a single [SyncEngine.sync] call (push then pull).
///
/// Wraps the [PullResult] from the pull half of the cycle. [SyncEngine.push]
/// currently returns `Future<void>` and reports nothing structured — [pull]
/// is therefore the only field today.
///
/// ## Why a wrapper instead of returning [PullResult] directly (finding A3, Q3)
///
/// This change lands before the 0.1.0 API freeze (WI-9). Returning a bare
/// [PullResult] from [SyncEngine.sync] now would make adding push-side
/// reporting later a second breaking signature change after the freeze.
/// [SyncResult] exists purely to reserve that extension point: a future
/// `push` field can be added here without changing [sync]'s return type
/// again.
final class SyncResult {
  /// Creates a [SyncResult].
  const SyncResult({required this.pull});

  /// The result of the pull half of this sync cycle.
  final PullResult pull;
}
