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

// ignore_for_file: avoid_print

import 'package:icu_tokenizer/icu_tokenizer.dart';

/// Demonstrates ICU and RegExp tokenizers side-by-side on a range of inputs.
///
/// Run with:
///   dart run example/icu_tokenizer_example.dart
void main() {
  _section('ICU tokenizer (UAX #29)', IcuTokenizer());
  _section('RegExp fallback tokenizer', RegExpTokenizer());
}

void _section(String label, Tokenizer t) {
  print('=== $label ===\n');

  _demo(
    t,
    'Jekyll description (prose)',
    '"The Strange Case of Dr. Jekyll and Mr. Hyde" by Robert Louis Stevenson '
        'is a Gothic horror novella published in 1886. When London lawyer Gabriel '
        'John Utterson investigates strange occurrences involving his old friend '
        'Dr. Henry Jekyll and a murderous criminal named Edward Hyde, he uncovers '
        'a disturbing mystery.',
  );

  _demo(
    t,
    'Technical identifiers',
    'Error code 0x8004210B occurred in mTLS handshake; see RFC 8446 §4.2.11.',
  );

  _demo(
    t,
    'Mixed punctuation & numbers',
    "It's a well-known fact that 3.14 ≈ π, isn't it?",
  );

  _demo(t, 'Empty string', '');

  print('');
}

void _demo(Tokenizer t, String label, String input) {
  final tokens = t.tokenise(input);
  final preview = input.length > 60 ? '${input.substring(0, 57)}...' : input;
  print('  [$label]');
  print('  input : $preview');
  print('  tokens: $tokens');
  print('  count : ${tokens.length}');
  print('');
}
