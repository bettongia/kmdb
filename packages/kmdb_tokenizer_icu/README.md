# kmdb_tokenizer_icu

ICU-backed word tokenizer for KMDB lexical search.

This package provides `IcuTokenizer`, an implementation of the `Tokenizer`
interface (defined in `package:kmdb`) that segments text using the ICU C library
and the Unicode UAX #29 word-break algorithm. It is a drop-in substitute for the
default `RegExpTokenizer` when full UAX #29 compliance is required — for
example, correct handling of mixed-script text or technical identifiers
containing punctuation.

ICU is a system library on all supported platforms (macOS, Linux, iOS, Android)
and requires no additional bundling.

## When to use this package

`RegExpTokenizer` (built into `package:kmdb`) produces equivalent output to
`IcuTokenizer` for English prose and common technical identifiers. Prefer
`IcuTokenizer` when:

- You need strict UAX #29 word-break compliance
- Your content mixes scripts or contains edge-case punctuation that
  `RegExpTokenizer` does not handle correctly

## Getting started

This package is part of the KMDB pub workspace and is not published to pub.dev.
Add it to your workspace `pubspec.yaml`:

```yaml
workspace:
  - packages/kmdb
  - packages/kmdb_tokenizer_icu
  # ...
```

ICU must be present on the host system. On macOS and iOS it is provided by the
OS. On Linux and Android it is available as `libicuuc`. Construction throws
`UnsupportedError` if the library cannot be loaded.

## Usage

Pass an `IcuTokenizer` to `FtsIndexDefinition` or `BertTokenizer` in place of
the default `RegExpTokenizer`:

```dart
import 'package:kmdb/kmdb.dart';
import 'package:kmdb_tokenizer_icu/kmdb_tokenizer_icu.dart';

final tokenizer = IcuTokenizer();

// Use with a lexical search index
final db = await KmdbDatabase.open(
  store,
  ftsIndexes: [
    FtsIndexDefinition(
      collection: 'books',
      field: 'description',
      tokenizer: tokenizer,
    ),
  ],
);

// Or tokenise text directly
final tokens = tokenizer.tokenise('The quick-brown fox.');
// ['The', 'quick', 'brown', 'fox']
```

## See also

- `package:kmdb` — core library; defines the `Tokenizer` interface and
  `RegExpTokenizer`
- `package:kmdb_inferencing` — ONNX runtime and BGE embedding model for semantic
  search; also accepts a `Tokenizer`
- KMDB specification §21 — lexical search preprocessing pipeline
