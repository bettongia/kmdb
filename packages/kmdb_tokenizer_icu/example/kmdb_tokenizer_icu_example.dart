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

import 'package:kmdb_tokenizer_icu/kmdb_tokenizer_icu.dart';

/// Example demonstrating [IcuTokenizer] usage.
void main() {
  final tokenizer = IcuTokenizer();
  final tokens = tokenizer.tokenise(
    '"The Strange Case of Dr. Jekyll and Mr. Hyde" by Robert Louis Stevenson.',
  );
  print('Tokens: $tokens');
}
