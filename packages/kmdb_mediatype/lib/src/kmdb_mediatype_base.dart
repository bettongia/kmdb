// Copyright 2026 The Aurochs KMesh Authors
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

import 'dart:typed_data';

import 'package:aurochs_registry_freedesktop_mimeinfo/registry.dart'
    as registry
    show MatchList, detect;

registry.MatchList detect({
  Uint8List? bytes,
  String? fileName,
  bool caseSensitive = false,
}) {
  return registry.detect(
    bytes: bytes,
    fileName: fileName,
    caseSensitive: caseSensitive,
  );
}
