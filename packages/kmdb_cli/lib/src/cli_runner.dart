// Copyright 2026 The KMDB Authors.
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

/// Entry point for the KMDB CLI.
///
/// [KmdbCli.run] parses [args] and dispatches to the appropriate command.
/// This stub will be expanded in Phase 1.
abstract final class KmdbCli {
  /// Runs the CLI with the given command-line [args].
  static Future<void> run(List<String> args) async {
    // TODO(phase1): implement command dispatch.
    throw UnimplementedError('CLI not yet implemented');
  }
}
