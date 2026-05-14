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

/// An abstract interface for reading and writing the raw JSON content of a
/// KMDB configuration file.
///
/// [KmdbConfig] delegates all I/O to this interface, keeping the config
/// parsing and mutation logic platform-neutral.  Concrete implementations
/// are responsible only for the raw string I/O; [KmdbConfig] handles all
/// JSON parsing and serialisation.
///
/// ## Implementations
///
/// - [IoKmdbConfigStore] — the standard `dart:io` implementation for native
///   platforms (macOS, Linux, Windows, iOS, Android).  Not supported on web.
/// - Custom implementations can be supplied for testing (e.g. an in-memory
///   store) or for alternative platforms (e.g. a future `WebKmdbConfigStore`
///   backed by IndexedDB or localStorage).
///
/// ## Usage with [KmdbConfig]
///
/// ```dart
/// // Native — convenience factory handles store wiring for you:
/// final config = await KmdbConfig.forDatabase('/path/to/db');
///
/// // Custom store (e.g. for tests):
/// final store = MyConfigStore();
/// final config = await KmdbConfig.load(store);
/// ```
abstract interface class KmdbConfigStore {
  /// Reads the raw JSON string from the backing store.
  ///
  /// Returns `null` when no config has been written yet (i.e. the config
  /// file does not exist).  Must not return an empty string; callers treat
  /// `null` as "missing" and an empty string as corrupt JSON.
  Future<String?> read();

  /// Writes [json] to the backing store, replacing any previous content.
  ///
  /// Implementations should use an atomic write strategy (e.g.
  /// write-to-temp-then-rename on native) so the file is never partially
  /// written.
  Future<void> write(String json);
}
