JSON Schema validation primitives for KMDB.

`kmdb_schema` provides the low-level building blocks used by KMDB's collection
schema feature (spec §25): individual validator functions, a sealed `SchemaRule`
rule tree, and a `SchemaParser` that compiles a JSON Schema map into a rule tree
for fast, repeated validation.

This package has no dependency on the KMDB storage engine and can be used
independently in any Dart project that needs structural document validation.

## Features

- **Primitive validators** — typed, composable validators for numeric ranges,
  string length/pattern/format, array bounds, enumerations, and required fields.
- **Format validators** — regex-based surface checks for `email`, `uri`, `date`,
  `date-time`, `time`, `uuid`, `duration`, `hex-string`, `digit-string`,
  `roman-numeral`, and `isbn-13`.
- **SchemaRule tree** — a sealed `SchemaRule` hierarchy that represents a parsed
  JSON Schema as an in-memory rule tree. Rules always collect all violations in
  one pass so every error is reported at once.
- **SchemaParser** — compiles a `Map<String, dynamic>` JSON Schema into a
  `SchemaRule` tree. Unknown keywords are silently ignored for forward
  compatibility.
- **SchemaViolation** — carries the dot-path to the offending field and a
  human-readable message.

## Supported JSON Schema keywords

| Keyword | Rule type |
| :--- | :--- |
| `type` | `TypeRule` |
| `required` | `RequiredRule` |
| `properties` | `PropertiesRule` |
| `additionalProperties: false` | `AdditionalPropertiesRule` |
| `enum` | `EnumRule` |
| `minimum` / `maximum` | `NumericRule` |
| `exclusiveMinimum` / `exclusiveMaximum` | `NumericRule` |
| `minLength` / `maxLength` | `StringRule` |
| `pattern` | `StringRule` |
| `format` | `FormatRule` |
| `minItems` / `maxItems` | `ArrayRule` |
| `items` | `ArrayRule` |

`additionalProperties` defaults to `true` (permissive). Set it explicitly to
`false` to reject undeclared fields.

## Usage

### Parsing and validating a document

```dart
import 'package:kmdb_schema/schema.dart';

final rule = SchemaParser().parse({
  'required': ['name', 'email'],
  'properties': {
    'name': {'type': 'string', 'minLength': 1},
    'email': {'type': 'string', 'format': 'email'},
    'age':  {'type': 'integer', 'minimum': 0},
  },
  'additionalProperties': false,
});

final violations = rule.validate({'name': 'Alice'}, '');
// → [SchemaViolation(path: 'email', message: 'required field is missing')]

for (final v in violations) {
  print(v); // "email: required field is missing"
}
```

### Using primitive validators directly

```dart
import 'package:kmdb_schema/schema.dart';

final inRange = Minimum(0) & Maximum(100);
print(inRange(42));  // true
print(inRange(101)); // false

final shortEnough = MaximumLength(20);
print(shortEnough('hello')); // true

final emailFmt = StringFormatValidator().getValidator('email')!;
print(emailFmt.function('user@example.com')); // true
print(emailFmt.function('not-an-email'));      // false
```

### SchemaViolation

Each violation carries a dot-path and a message:

```dart
final v = SchemaViolation(path: 'address.city', message: 'required field is missing');
print(v.path);    // address.city
print(v.message); // required field is missing
print(v);         // address.city: required field is missing
```

Root-level violations use an empty `path`:

```dart
final root = SchemaViolation(path: '', message: 'expected type object');
print(root); // expected type object
```

## Additional information

This package is guided by the [JSON Schema](https://json-schema.org/)
specification — specifically
[JSON Schema Validation: A Vocabulary for Structural Validation of JSON](https://json-schema.org/draft/2020-12/json-schema-validation.html).

The subset of keywords implemented here corresponds to `schemaModelVersion: 1`
in KMDB's collection schema system (spec §25). Out-of-scope for v1: `$ref`,
`allOf`/`anyOf`/`oneOf`/`not`, `if`/`then`/`else`, and nested `$schema`
declarations.
