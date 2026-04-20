// Copyright 2025 The KMDB Authors
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

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dart_style/dart_style.dart';
import 'package:http/http.dart' as http;

final dartfmt = DartFormatter(
  languageVersion: DartFormatter.latestLanguageVersion,
);

enum CompressionType { none, zip }

/// Loads data from a file or URL.
///
/// If [force] is true, the data will be loaded from the URL even if the file exists.
/// If [compression] is [CompressionType.zip], the data will be uncompressed from a zip file.
/// For multi-part archives, the [archiveFilePath] parameter should be used to specify the path to the archive file.
Future<String> loadData(
  String filePath,
  String url, {
  bool force = false,
  CompressionType compression = CompressionType.none,
  String? archiveFilePath,
}) {
  // if the local file exists, read it
  if (!force && File(filePath).existsSync()) {
    print('Using local file: $filePath');
    return loadFromLocalFile(filePath);
  } else {
    // otherwise, read it from the URL
    print('Using URL: $url');
    return loadFromUrl(
      url,
      filePath,
      compression: compression,
      archiveFilePath: archiveFilePath,
    );
  }
}

Future<String> _uncompress(
  Uint8List input,
  CompressionType compression,
  String? archiveFilePath,
) async {
  switch (compression) {
    case CompressionType.none:
      return utf8.decode(input);
    case CompressionType.zip:
      return utf8.decode(await _uncompressZip(input, archiveFilePath));
  }
}

Future<Uint8List> _uncompressZip(
  Uint8List input,
  String? archiveFilePath,
) async {
  final archive = ZipDecoder().decodeBytes(input);
  if (archive.isEmpty) {
    return Future.error('Archive is empty');
  }

  final entry = (archiveFilePath == null)
      ? archive.first
      : archive.find(archiveFilePath);

  if (entry == null) {
    return Future.error(
      'Archive must contain exactly one file or contain the file at the specified path',
    );
  }

  if (!entry.isFile) {
    return Future.error('The requested entry is not a file');
  }

  // Read the entry into a string
  final fileBytes = entry.readBytes();
  if (fileBytes == null) {
    return Future.error('Failed to read file');
  }
  return fileBytes;
}

Future<String> loadFromLocalFile(String filePath) async =>
    await File(filePath).readAsString();

Future<String> loadFromUrl(
  String url,
  String cacheFile, {
  CompressionType compression = CompressionType.none,
  String? archiveFilePath,
}) async {
  final response = await http.get(Uri.parse(url));
  if (response.statusCode != 200) {
    return Future.error('Failed to load data: ${response.statusCode}');
  }

  final content = await _uncompress(
    response.bodyBytes,
    compression,
    archiveFilePath,
  );

  print('Writing content to file: $cacheFile');
  File(cacheFile).writeAsStringSync(
    content,
    flush: true,
    mode: FileMode.write,
    encoding: utf8,
  );

  return content;
}
