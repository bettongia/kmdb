// Copyright 2026 The KMDB Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'package:kmdb/kmdb.dart';

import 'command.dart';

/// Verifies that every document in every namespace can be decoded correctly.
///
/// This is a read-only operation: it scans all namespaces and attempts to
/// decode each stored value using [ValueCodec]. Any corrupt or undecodable
/// value is reported as an error.
///
/// Usage: `kmdb <db> verify`
final class VerifyCommand implements CliCommand {
  const VerifyCommand();

  @override
  String get name => 'verify';

  @override
  String get description =>
      'Verify all stored documents can be decoded without errors.';

  @override
  String get usage => 'verify';

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    final namespaces = await ctx.store.listNamespaces();
    var checked = 0;
    final errors = <Map<String, dynamic>>[];

    for (final ns in namespaces) {
      await for (final entry in ctx.store.scan(ns)) {
        checked++;
        try {
          ValueCodec.decode(entry.value);
        } catch (e) {
          errors.add({
            'namespace': ns,
            'key': entry.key,
            'error': '$e',
          });
        }
      }
    }

    ctx.writeValue({
      'checked': checked,
      'errors': errors.length,
      if (errors.isNotEmpty) 'details': errors,
    });

    return errors.isEmpty;
  }
}
