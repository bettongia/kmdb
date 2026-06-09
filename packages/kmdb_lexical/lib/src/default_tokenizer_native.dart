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
/// On native, [RegExpTokenizer] is used: a pure-Dart tokenizer based on the
/// Unicode `\p{L}\p{N}` character classes that requires no native library and
/// works identically across all native targets.
///
/// The companion file `default_tokenizer_web.dart` is selected instead when
/// running on web via the conditional export in `lexical.dart`.
Tokenizer createDefaultTokenizer() => RegExpTokenizer();
