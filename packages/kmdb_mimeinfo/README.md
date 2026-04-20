# Aurochs Registry: Freedesktop MIME-info

A Dart implementation of the
[Freedesktop.org Shared MIME-info Database](https://specifications.freedesktop.org/shared-mime-info/latest/)
specification. This package provides a robust registry for identifying MIME
types through a combination of filename patterns (globs), magic numbers (content
matching), and RootXML element matching.

## Features

- **Spec-Compliant**: Implements the Freedesktop.org Shared MIME-info Database
  specification version 2.4.
- **Robust Identification**: Uses a prioritized identification algorithm:
  - **Magic Matching**: Content-based identification via byte patterns at
    specific offsets.
  - **Glob Matching**: Filename pattern matching (e.g., `*.png`, `*.tar.gz`).
  - **RootXML Matching**: XML-specific identification based on the root
    element's namespace and local name.
- **Rich Metadata**: Provides access to:
  - Human-readable descriptions (with internationalization support).
  - Subclass relationships (MIME inheritance).
  - Generic icons (XDG icon theme compatible).
  - Acronyms and aliases.
- **Performant**: Optimized for fast lookups with pre-compiled MIME database
  entries.

Note that **TreeMagic is not yet implemented** (Directory-level identification
based on internal file/folder structures.)

## Getting started

Add the package to your `pubspec.yaml`:

```yaml
dependencies:
  aurochs_registry_freedesktop_mimeinfo: ^1.0.0
```

## Usage

### Quick Start: Identifying a File

```dart
import 'dart:io';
import 'dart:typed_data' show Uint8List;

import 'package:aurochs_registry_freedesktop_mimeinfo/registry.dart';
import 'package:path/path.dart' as p;

final Uint8List bytes = File(filePath).readAsBytesSync();

final matches = detect(bytes: bytes, fileName: p.basename(filePath));
```

### Detailed Identification

The `detect` method returns a list of `MatchList` objects, sorted by priority
and confidence. See [example.dart](example/example.dart).

## Command Line Interface (CLI)

The package includes a CLI tool called `detect` to quickly check the media type
of a file.

### Usage

Run the tool from the root of the package:

```sh
dart bin/identify.dart <filename>
```

There's a number of test files in `test/data/`:

```sh
dart run bin/detect.dart test/data/application/docbook_5.xml
```

## More Examples

Check the [example/](example/) folder for a complete demonstration of the
package's capabilities.

## Building the registry

The contents of [lib/src/g](lib/src/g) are generated using the
[`tool/loader.dart`](tool/loader.dart) script. In order to run the script:

1. Visit https://gitlab.freedesktop.org/xdg/shared-mime-info/-/releases and
   download the latest release (e.g. the
   [2.4 zip](https://gitlab.freedesktop.org/xdg/shared-mime-info/-/archive/2.4/shared-mime-info-2.4.zip)).
2. Extract the zip and locate `data/freedesktop.org.xml.in` - rename this file
   to `freedesktop.org.xml` and copy it to `tool/data` in this project
3. From this project's root, run `dart run tool/loader.dart`
4. You'll see the generated files appear/update in `lib/src/g`

If you blew away `lib/src/g` for some reason, you will need to edit
`lib/registry.dart` before you run the loader.

## The Freedesktop.org Shared MIME-info Database

This package makes use of the
[Freedesktop.org Shared MIME-info Database](https://specifications.freedesktop.org/shared-mime-info/latest/).
The database itself carries the following license:

    The freedesktop.org shared MIME database (this file) was created by merging
    several existing MIME databases (all released under the GNU GPL).

    It comes with ABSOLUTELY NO WARRANTY, to the extent permitted by law. You may
    redistribute copies of freedesktop.org.xml under the terms of the GNU General
    Public License version 2 or later. For more information about these matters, see
    the file named COPYING.

    The latest version is available from:

          http://www.freedesktop.org/wiki/Software/shared-mime-info/

    To extend this database, users and applications should create additional XML
    files in the 'packages' directory and run the update-mime-database command to
    generate the output files.

See also:

- https://www.freedesktop.org/wiki/Specifications/shared-mime-info-spec/
