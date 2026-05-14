// Copyright 2026 The Authors
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

import 'dart:ffi';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

/// ONNX Runtime release to use. Bump this string to upgrade.
const _ortVersion = '1.22.0';

/// Resolves, downloads if needed, and opens the ORT native shared library.
///
/// On Android the `.so` is bundled by Gradle and loaded by name. On all other
/// supported platforms (macOS, Linux, Windows) the library is downloaded from
/// the ONNX Runtime GitHub Releases on first use and cached next to the
/// compiled executable.
///
/// Throws [UnsupportedError] on unsupported platforms (e.g. web).
Future<DynamicLibrary> openOrtLibrary() async {
  if (Platform.isAndroid) {
    // Android: the .so is placed in the APK lib/ directory by Gradle.
    // The dynamic linker resolves it by name at runtime — no path needed.
    return DynamicLibrary.open('libonnxruntime.so');
  }

  final libPath = await _ensureLibraryPresent();
  return DynamicLibrary.open(libPath);
}

// ── Private helpers ───────────────────────────────────────────────────────────

Future<String> _ensureLibraryPresent() async {
  final libName = _platformLibraryName();
  final libDir = _executableDirectory();
  final libPath = p.join(libDir, libName);

  if (File(libPath).existsSync()) return libPath;

  // Library not cached — download from GitHub Releases.
  print(
    '[kmdb_inferencing] Native ORT library not found, downloading $_ortVersion...',
  );
  await _downloadAndExtract(libDir, libName);
  print('[kmdb_inferencing] Download complete: $libPath');

  return libPath;
}

/// Returns the platform-specific shared-library filename.
String _platformLibraryName() {
  if (Platform.isLinux) return 'libonnxruntime.so.$_ortVersion';
  if (Platform.isMacOS) return 'libonnxruntime.$_ortVersion.dylib';
  if (Platform.isWindows) return 'onnxruntime.dll';
  throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
}

/// Stores the library next to the compiled executable so it persists across
/// process restarts.
String _executableDirectory() => File(Platform.resolvedExecutable).parent.path;

Future<void> _downloadAndExtract(String libDir, String libName) async {
  final (archiveName, innerPath) = _archiveDetails();
  final url =
      'https://github.com/microsoft/onnxruntime/releases/download'
      '/v$_ortVersion/$archiveName';

  final response = await http.get(Uri.parse(url));
  if (response.statusCode != 200) {
    throw Exception(
      'Failed to download ORT (HTTP ${response.statusCode}): $url',
    );
  }

  final bytes = response.bodyBytes;
  final outFile = File(p.join(libDir, libName));

  if (archiveName.endsWith('.zip')) {
    for (final file in ZipDecoder().decodeBytes(bytes)) {
      if (file.name.endsWith(innerPath)) {
        await outFile.writeAsBytes(file.content as List<int>);
        return;
      }
    }
  } else {
    // .tgz
    final tar = TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes));
    for (final file in tar) {
      if (file.name.endsWith(innerPath)) {
        await outFile.writeAsBytes(file.content as List<int>);
        return;
      }
    }
  }

  throw Exception('Expected library not found inside archive: $innerPath');
}

/// Returns (archiveFilename, pathSuffixOfLibInsideArchive) for the current
/// platform and CPU architecture.
(String, String) _archiveDetails() {
  final arch = _cpuArch();

  if (Platform.isLinux) {
    return (
      'onnxruntime-linux-$arch-$_ortVersion.tgz',
      'lib/libonnxruntime.so.$_ortVersion',
    );
  }
  if (Platform.isMacOS) {
    return (
      'onnxruntime-osx-$arch-$_ortVersion.tgz',
      'lib/libonnxruntime.$_ortVersion.dylib',
    );
  }
  if (Platform.isWindows) {
    return ('onnxruntime-win-$arch-$_ortVersion.zip', 'lib/onnxruntime.dll');
  }
  throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
}

/// Detects x64 vs arm64 from Dart's version string.
String _cpuArch() {
  final ver = Platform.version.toLowerCase();
  if (ver.contains('arm64') || ver.contains('aarch64')) return 'arm64';
  return 'x64';
}
