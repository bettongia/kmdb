# kmdb_lexical

Lexical text utilities used by the KMDB BM25 full-text search engine.

This package provides the language-side primitives used in the KMDB
preprocessing pipeline (§21):

- A regex-based default tokenizer (`RegExpTokenizer`).
- A vendored Snowball English stemmer.
- A curated default English stopword list.

These utilities are consumed by the `FtsManager` in `package:kmdb` and by the
`kmdb search` CLI command. They are intentionally lightweight and have no
dependencies on the storage engine — applications can also use them directly to
pre-tokenise text before storage.

## Usage

```dart
import 'package:kmdb_lexical/lexical.dart';

final tokens = const RegExpTokenizer().tokenise('Hello, mTLS world');
final stemmed = tokens.map(stem).toList();
final filtered = stemmed.where((t) => !defaultStopwords.contains(t));
```

## Status

Internal package — not published to pub.dev. The Snowball stemmer under
`lib/src/third_party/` retains its original BSD-style license.

## License

Apache-2.0 (excluding `lib/src/third_party/`, which is BSD-licensed).
