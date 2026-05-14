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

/// ICU-backed word tokenizer for KMDB lexical search.
///
/// Provides [IcuTokenizer], which implements the [Tokenizer] interface using
/// the system ICU C library. Conforms to UAX #29 Unicode Text Segmentation,
/// making it suitable for non-Latin scripts (CJK, Thai, Arabic, etc.).
///
/// ICU is a system library on all KMDB target platforms — no bundling required.
/// For English-only use cases, [RegExpTokenizer] from the `kmdb` package is a
/// simpler zero-FFI alternative.
library;

export 'src/icu_tokenizer.dart' show IcuTokenizer;
