// Copyright 2026 The KMDB Authors
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

/// Shared helpers for KMDB benchmarks.
library;

import 'package:kmdb/kmdb.dart';

final _keyGen = UuidV7KeyGenerator();

/// Returns a fresh UUIDv7 key suitable for use as a document `_id`.
String generateKey() => _keyGen.next();

/// Returns a ~200-byte document payload without an `_id` field.
///
/// Pass to [KmdbCollection.insert] which assigns the key automatically.
Map<String, dynamic> benchPayload(int index) => {
  'name': 'Benchmark Document $index',
  'category': 'performance',
  'value': index,
  'active': true,
  'tags': ['bench', 'kmdb', 'perf'],
  'description': 'A fixed-size document used as a consistent benchmark payload '
      'to exercise the write and read paths with realistic field counts.',
};

/// Returns a ~200-byte document with a pre-assigned [id] in the `_id` field.
///
/// Pass to [KmdbCollection.put] when the key is already known.
Map<String, dynamic> benchDoc(String id, int index) => {
  '_id': id,
  ...benchPayload(index),
};
