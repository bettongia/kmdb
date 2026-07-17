// Copyright 2026 The Authors.
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

import 'package:kmdb_cli/src/commands/collections_command.dart';
import 'package:kmdb_cli/src/commands/command.dart';
import 'package:kmdb_cli/src/commands/compact_command.dart';
import 'package:kmdb_cli/src/commands/count_command.dart';
import 'package:kmdb_cli/src/commands/create_collection_command.dart';
import 'package:kmdb_cli/src/commands/delete_command.dart';
import 'package:kmdb_cli/src/commands/dump_command.dart';
import 'package:kmdb_cli/src/commands/export_command.dart';
import 'package:kmdb_cli/src/commands/flush_command.dart';
import 'package:kmdb_cli/src/commands/get_command.dart';
import 'package:kmdb_cli/src/commands/import_command.dart';
import 'package:kmdb_cli/src/commands/index_command.dart';
import 'package:kmdb_cli/src/commands/info_command.dart';
import 'package:kmdb_cli/src/commands/init_command.dart';
import 'package:kmdb_cli/src/commands/insert_command.dart';
import 'package:kmdb_cli/src/commands/new_device_id_command.dart';
import 'package:kmdb_cli/src/commands/pull_command.dart';
import 'package:kmdb_cli/src/commands/push_command.dart';
import 'package:kmdb_cli/src/commands/remote_command.dart';
import 'package:kmdb_cli/src/commands/restore_command.dart';
import 'package:kmdb_cli/src/commands/scan_command.dart';
import 'package:kmdb_cli/src/commands/schema_command.dart';
import 'package:kmdb_cli/src/commands/search_command.dart';
import 'package:kmdb_cli/src/commands/stats_command.dart';
import 'package:kmdb_cli/src/commands/sync_command.dart';
import 'package:kmdb_cli/src/commands/update_command.dart';
import 'package:kmdb_cli/src/commands/util_command.dart';
import 'package:kmdb_cli/src/commands/vault/vault_command.dart';
import 'package:kmdb_cli/src/commands/vault/vault_export_command.dart';
import 'package:kmdb_cli/src/commands/vault/vault_get_command.dart';
import 'package:kmdb_cli/src/commands/vault/vault_reindex_command.dart';
import 'package:kmdb_cli/src/commands/vault/vault_search_command.dart';
import 'package:kmdb_cli/src/commands/vault/vault_status_command.dart';
import 'package:kmdb_cli/src/commands/verify_command.dart';
import 'package:test/test.dart';

void main() {
  // All known CliCommand subclasses. Extending this list when a new command is
  // added ensures the metadata contract is automatically enforced.
  final commands = <CliCommand>[
    const CollectionsCommand(),
    const CompactCommand(),
    const CountCommand(),
    const CreateCollectionCommand(),
    const DeleteCommand(),
    const DumpCommand(),
    const ExportCommand(),
    const FlushCommand(),
    const GetCommand(),
    const ImportCommand(),
    const IndexCommand(),
    const InfoCommand(),
    const InitCommand(),
    const InsertCommand(),
    const NewDeviceIdCommand(),
    const PullCommand(),
    const PushCommand(),
    const RemoteCommand(),
    const RestoreCommand(),
    const ScanCommand(),
    const SchemaCommand(),
    const SearchCommand(),
    const StatsCommand(),
    const SyncCommand(),
    const UpdateCommand(),
    const UtilCommand(),
    const VaultCommand(),
    const VaultExportCommand(),
    const VaultGetCommand(),
    const VaultReindexCommand(),
    const VaultSearchCommand(),
    const VaultStatusCommand(),
    const VerifyCommand(),
  ];

  group('CliCommand metadata', () {
    for (final cmd in commands) {
      group(cmd.runtimeType.toString(), () {
        test('name is a non-empty string', () {
          expect(cmd.name, isA<String>());
          expect(cmd.name, isNotEmpty);
        });

        test('description is a non-empty string', () {
          expect(cmd.description, isA<String>());
          expect(cmd.description, isNotEmpty);
        });

        test('usage is a non-empty string', () {
          expect(cmd.usage, isA<String>());
          expect(cmd.usage, isNotEmpty);
        });

        test('configureArgParser completes without error', () {
          expect(() => cmd.configureArgParser(ArgParser()), returnsNormally);
        });
      });
    }
  });
}
