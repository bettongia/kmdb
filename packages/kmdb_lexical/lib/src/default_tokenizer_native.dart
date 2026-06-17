// Copyright 2026 The Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'package:betto_icu/betto_icu.dart';

/// Returns the default [Tokenizer] for native platforms.
///
/// On native, [IcuTokenizer] is used: it delegates to the system ICU library
/// via FFI and conforms to UAX #29 Unicode Text Segmentation. This handles
/// non-Latin scripts (CJK, Thai, Arabic, etc.) correctly, making it suitable
/// for multi-language content. ICU is a system library on every native target:
/// `libicucore.dylib` on macOS/iOS, `libicuuc.so` on Android/Linux, and
/// `icu.dll` on Windows — no bundling is required.
///
/// Use [RegExpTokenizer] directly when FFI is unavailable or a pure-Dart,
/// English-only fallback is explicitly needed.
///
/// The companion file `default_tokenizer_web.dart` is selected instead when
/// running on web via the conditional export in `lexical.dart`.
Tokenizer createDefaultTokenizer() => IcuTokenizer();
