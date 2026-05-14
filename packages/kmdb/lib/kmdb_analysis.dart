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

/// Diagnostic sub-library for KMDB storage-engine inspection.
///
/// Exposes storage-engine internals for use by diagnostic tooling such as
/// the `kmdb util` CLI subcommands. These types are **not** part of the
/// primary application API exported by `package:kmdb/kmdb.dart`; adding
/// storage internals to the main library would pollute the API surface and
/// impose a maintenance burden on consumers who only need the query layer.
///
/// **No backwards-compatibility guarantee** beyond the stable versioning of
/// the `kmdb` package itself. Types in this library may change between minor
/// versions as storage-engine internals evolve.
///
/// ## Typical usage
///
/// ```dart
/// import 'package:kmdb/kmdb_analysis.dart';
///
/// final reader = await SstableReader.open(path, adapter);
/// print(reader.footer.toMap());
/// ```
library;

export 'src/engine/sstable/sstable_reader.dart'
    show SstableReader, SstEntry, BlockRef, CorruptedSstableException;
export 'src/engine/sstable/sstable_writer.dart' show SstableFooter;
export 'src/engine/sstable/bloom_filter.dart' show BloomFilter;
export 'src/engine/util/hlc.dart' show Hlc;
export 'src/engine/util/key_codec.dart' show KeyCodec;
export 'src/engine/wal/wal_reader.dart' show WalReader;
export 'src/engine/wal/wal_record.dart' show WalRecord, WalRecordType;
export 'src/engine/wal/wal_exceptions.dart' show CorruptedWalException;
export 'src/engine/manifest/manifest_reader.dart'
    show ManifestReader, ManifestState;
export 'src/engine/manifest/version_edit.dart' show VersionEdit, SstableMeta;
