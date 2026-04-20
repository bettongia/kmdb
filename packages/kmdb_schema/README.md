Provides functionality for validating data against a schema.

## Features

A variety of `Validator`s are provided to validate data against a semantic
requirement - such as ensuring a number is within a range.

## Usage

Set a maximum value and validate values against it:

```dart
var max = Maximum(5);
expect(max(5), isTrue);
expect(max(6), isFalse);
```

The tests also provide a range of examples.

## Additional information

This package is guided by the [JSON Schema](https://json-schema.org/)
specification - with validation using
[JSON Schema Validation: A Vocabulary for Structural Validation of JSON](https://json-schema.org/draft/2020-12/json-schema-validation.html)
