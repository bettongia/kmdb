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

/// Markdown text extractor for KMDB vault search.
///
/// Provides [MarkdownTextExtractor] — a `VaultTextExtractor` implementation
/// (defined in `package:kmdb`) for `text/markdown` vault blobs, using the
/// [markdown](https://pub.dev/packages/markdown) package's AST parser.
///
/// ## Quick start
///
/// ```dart
/// import 'package:kmdb/kmdb.dart';
/// import 'package:kmdb_extractor_markdown/kmdb_extractor_markdown.dart';
///
/// final db = await KmdbDatabase.open(
///   path: '/path/to/db',
///   adapter: adapter,
///   vaultStore: vaultStore,
///   vaultSearch: VaultSearchConfig(extractors: [MarkdownTextExtractor()]),
/// );
/// ```
///
/// ## Platform support
///
/// This package runs exclusively in the native-only vault indexing pipeline
/// (see `package:kmdb`'s `VaultSearchManager`) — vault content search is not
/// available on web. Like `kmdb_extractor_html`, this package is pure Dart
/// with no native/FFI dependencies, so it has no additional platform
/// restrictions of its own beyond that shared vault-search scope.
library;

export 'src/markdown_text_extractor.dart' show MarkdownTextExtractor;
