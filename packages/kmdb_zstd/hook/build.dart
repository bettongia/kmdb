// Copyright 2026 The KMDB Authors
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

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

/// Build hook for native assets.
///
/// Compiles the Zstd C library for the target platform.
void main(List<String> args) async {
  print('hello');
  await build(args, (input, output) async {
    final cBuilder = CBuilder.library(
      name: 'zstd',
      assetName: 'src/zstd_base.dart',
      sources: ['third_party/zstd/src/zstd.c'],
      linkModePreference: input.config.linkingEnabled
          ? LinkModePreference.static
          : LinkModePreference.dynamic,
    );
    await cBuilder.run(
      input: input,
      output: output,
      logger: Logger('')
        ..level = Level.ALL
        ..onRecord.listen((record) => print(record.message)),
      routing: input.config.linkingEnabled
          ? [ToLinkHook(input.packageName)]
          : [const ToAppBundle()],
    );
  });
}
