/*
 Copyright 2026 The Authors

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

      https://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

import 'dart:io';
import 'dart:typed_data' show Uint8List;

import 'package:kmdb_mimeinfo/registry.dart' show detect;
import 'package:path/path.dart' as p;

/// A simple CLI application that identifies the media type of a file
/// based on its name using the FreeDesktop shared-mime-info registry.
int main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('Error: no filename provided.');
    exit(1);
  }

  final String filePath = args.first;

  final Uint8List bytes = File(filePath).readAsBytesSync();

  final matches = detect(bytes: bytes, fileName: p.basename(filePath));

  if (matches.isEmpty) {
    print('No media type match found for: $filePath');
    exit(0);
  } else {
    print('Best match is: ${matches.bestMatch}\n');
    print('These are the merged results:');
    // The results are ordered by descending weight.
    for (final m in matches.merged) {
      print('- ${m.mediaType} [priority: ${m.priority}]');
    }

    print(
      '\nThese are the candidate media types in descending order of priority:',
    );
    for (final m in matches.candidates) {
      print('- $m');
    }

    print(
      '\nThese are the candidate media types (full info) in descending order of priority:',
    );
    for (final m in matches.combined) {
      print('- ${m.mediaType} [priority: ${m.priority}]');
    }

    print('\nThese are the results from each check type:');
    print('- Globs:');
    for (final m in matches.globMatches) {
      print('  - ${m.mediaType} [priority: ${m.priority}]');
    }
    print('- Magic:');
    for (final m in matches.magicMatches) {
      print('  - ${m.mediaType} [priority: ${m.priority}]');
    }
    print('- Root XML:');
    for (final m in matches.rootXmlMatches) {
      print('  - ${m.mediaType} [priority: ${m.priority}]');
    }
    exit(0);
  }
}
