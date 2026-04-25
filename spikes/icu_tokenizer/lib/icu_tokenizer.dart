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

/// Spike: UAX #29 word segmentation via ICU FFI, with a pure-Dart fallback.
///
/// Exports:
/// - [Tokenizer] — abstract segmentation interface
/// - [IcuTokenizer] — FFI-backed implementation using the system ICU library
/// - [RegExpTokenizer] — pure-Dart fallback for unsupported platforms
library;

export 'src/icu_tokenizer.dart' show IcuTokenizer;
export 'src/regexp_tokenizer.dart' show RegExpTokenizer;
export 'src/tokenizer.dart' show Tokenizer;
