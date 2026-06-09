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

/// Returns the default [Tokenizer] for web platforms.
///
/// On web, [BrowserTokenizer] is used: it delegates to the browser's native
/// `Intl.Segmenter` API via `dart:js_interop`, giving UAX #29-quality word
/// segmentation at zero bundle cost (the browser's own ICU handles it).
///
/// The companion file `default_tokenizer_native.dart` is selected instead when
/// running on native via the conditional export in `lexical.dart`.
Tokenizer createDefaultTokenizer() => BrowserTokenizer();
