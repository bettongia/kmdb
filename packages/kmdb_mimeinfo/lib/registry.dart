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

import 'dart:typed_data';

export 'src/registry_base.dart' show MatchResult, MatchList, Registry;

import 'src/registry_base.dart';

// Note: you likely need to comment these next 2 lines out out if you're
// rebuilding the `g` folder using `tool/loader.dart`
import 'src/g/mimeinfo.dart' show mimeinfoDb;

final _mimeInfoRegistry = Registry(mimeinfoDb);

MatchList detect({
  Uint8List? bytes,
  String? fileName,
  bool caseSensitive = false,
}) => _mimeInfoRegistry.detect(
  bytes: bytes,
  fileName: fileName,
  caseSensitive: caseSensitive,
);
