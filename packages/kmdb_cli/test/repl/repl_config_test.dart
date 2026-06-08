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

import 'dart:convert';
import 'dart:io' as io;

import 'package:kmdb_cli/src/output/output_mode.dart';
import 'package:kmdb_cli/src/repl/repl_config.dart';
import 'package:kmdb_cli/src/repl/session_state.dart';
import 'package:test/test.dart';

void main() {
  late io.Directory tmp;
  late String configPath;

  setUp(() async {
    tmp = await io.Directory.systemTemp.createTemp('repl_config_test_');
    configPath = '${tmp.path}/.kmdbrc';
  });

  tearDown(() => tmp.delete(recursive: true));

  // ── Missing file ────────────────────────────────────────────────────────────

  group('missing config file', () {
    test('writes a defaults file', () async {
      await ReplConfig(filePath: configPath).load(SessionState());

      expect(io.File(configPath).existsSync(), isTrue);
    });

    test('written file is valid JSON', () async {
      await ReplConfig(filePath: configPath).load(SessionState());

      final text = await io.File(configPath).readAsString();
      expect(() => jsonDecode(text), returnsNormally);
    });

    test('written file contains all expected keys', () async {
      await ReplConfig(filePath: configPath).load(SessionState());

      final json =
          jsonDecode(await io.File(configPath).readAsString())
              as Map<String, dynamic>;
      for (final key in [
        'bail',
        'color',
        'compact',
        'echo',
        'headers',
        'limit',
        'mode',
        'nullvalue',
        'timer',
      ]) {
        expect(json, contains(key), reason: 'missing key: $key');
      }
    });

    test('state remains at defaults when file is absent', () async {
      final state = SessionState();
      await ReplConfig(filePath: configPath).load(state);

      expect(state.bail, isFalse);
      expect(state.compact, isFalse);
      expect(state.echo, isFalse);
      expect(state.headers, isTrue);
      expect(state.timer, isFalse);
      expect(state.defaultLimit, 0);
      expect(state.nullValue, '');
      expect(state.outputMode, OutputMode.json);
      expect(state.colorMode, ColorMode.auto);
    });
  });

  // ── Valid config file ───────────────────────────────────────────────────────

  group('valid config file', () {
    Future<void> writeConfig(Map<String, dynamic> json) =>
        io.File(configPath).writeAsString(jsonEncode(json));

    test('applies all bool fields', () async {
      await writeConfig({
        'bail': true,
        'compact': true,
        'echo': true,
        'headers': false,
        'timer': true,
      });
      final state = SessionState();
      await ReplConfig(filePath: configPath).load(state);

      expect(state.bail, isTrue);
      expect(state.compact, isTrue);
      expect(state.echo, isTrue);
      expect(state.headers, isFalse);
      expect(state.timer, isTrue);
    });

    test('applies limit', () async {
      await writeConfig({'limit': 50});
      final state = SessionState();
      await ReplConfig(filePath: configPath).load(state);

      expect(state.defaultLimit, 50);
    });

    test('applies nullvalue', () async {
      await writeConfig({'nullvalue': 'N/A'});
      final state = SessionState();
      await ReplConfig(filePath: configPath).load(state);

      expect(state.nullValue, 'N/A');
    });

    test('applies mode: table', () async {
      await writeConfig({'mode': 'table'});
      final state = SessionState();
      await ReplConfig(filePath: configPath).load(state);

      expect(state.outputMode, OutputMode.table);
    });

    test('applies color: on', () async {
      await writeConfig({'color': 'on'});
      final state = SessionState();
      await ReplConfig(filePath: configPath).load(state);

      expect(state.colorMode, ColorMode.on);
    });

    test('applies color: off', () async {
      await writeConfig({'color': 'off'});
      final state = SessionState();
      await ReplConfig(filePath: configPath).load(state);

      expect(state.colorMode, ColorMode.off);
    });

    test('unknown color value falls back to auto', () async {
      await writeConfig({'color': 'rainbow'});
      final state = SessionState();
      await ReplConfig(filePath: configPath).load(state);

      expect(state.colorMode, ColorMode.auto);
    });

    test('partial config leaves unmentioned fields at defaults', () async {
      await writeConfig({'bail': true});
      final state = SessionState();
      await ReplConfig(filePath: configPath).load(state);

      expect(state.bail, isTrue);
      expect(state.timer, isFalse); // untouched default
      expect(state.outputMode, OutputMode.json); // untouched default
    });

    test('unknown keys are ignored', () async {
      await writeConfig({'bail': true, 'future_setting': 42});
      final state = SessionState();
      await ReplConfig(filePath: configPath).load(state);

      expect(state.bail, isTrue); // known key applied
    });
  });

  // ── Invalid / corrupt config ────────────────────────────────────────────────

  group('invalid config', () {
    test('corrupt JSON leaves state at defaults', () async {
      await io.File(configPath).writeAsString('not json at all');
      final state = SessionState();
      await ReplConfig(filePath: configPath).load(state);

      expect(state.bail, isFalse);
      expect(state.outputMode, OutputMode.json);
    });

    test('JSON array (not object) leaves state at defaults', () async {
      await io.File(configPath).writeAsString('[1, 2, 3]');
      final state = SessionState();
      await ReplConfig(filePath: configPath).load(state);

      expect(state.outputMode, OutputMode.json);
    });

    test('wrong type for bool field is ignored', () async {
      await io.File(
        configPath,
      ).writeAsString(jsonEncode({'bail': 'yes', 'timer': 1}));
      final state = SessionState();
      await ReplConfig(filePath: configPath).load(state);

      expect(state.bail, isFalse);
      expect(state.timer, isFalse);
    });

    test('wrong type for limit is ignored', () async {
      await io.File(configPath).writeAsString(jsonEncode({'limit': 'lots'}));
      final state = SessionState();
      await ReplConfig(filePath: configPath).load(state);

      expect(state.defaultLimit, 0);
    });

    test('negative limit is ignored', () async {
      await io.File(configPath).writeAsString(jsonEncode({'limit': -1}));
      final state = SessionState();
      await ReplConfig(filePath: configPath).load(state);

      expect(state.defaultLimit, 0);
    });

    test('unknown mode string is ignored', () async {
      await io.File(configPath).writeAsString(jsonEncode({'mode': 'xml'}));
      final state = SessionState();
      await ReplConfig(filePath: configPath).load(state);

      expect(state.outputMode, OutputMode.json);
    });
  });

  // ── cacheDir ────────────────────────────────────────────────────────────────

  group('cacheDir', () {
    test('defaults to ~/.kmdb_cache when not set in config', () async {
      // Write a config without cacheDir.
      await io.File(configPath).writeAsString(jsonEncode({'bail': false}));
      final config = ReplConfig(filePath: configPath);
      await config.load(SessionState());

      // Should end with the default suffix regardless of HOME.
      expect(config.cacheDir, endsWith('.kmdb_cache'));
    });

    test('uses cacheDir from config when present', () async {
      const customDir = '/custom/model/cache';
      await io.File(
        configPath,
      ).writeAsString(jsonEncode({'cacheDir': customDir}));
      final config = ReplConfig(filePath: configPath);
      await config.load(SessionState());

      expect(config.cacheDir, equals(customDir));
    });

    test('empty cacheDir string falls back to default', () async {
      await io.File(configPath).writeAsString(jsonEncode({'cacheDir': ''}));
      final config = ReplConfig(filePath: configPath);
      await config.load(SessionState());

      // Empty string is treated as absent — fall back to system default.
      expect(config.cacheDir, endsWith('.kmdb_cache'));
    });

    test('whitespace-only cacheDir string falls back to default', () async {
      await io.File(configPath).writeAsString(jsonEncode({'cacheDir': '   '}));
      final config = ReplConfig(filePath: configPath);
      await config.load(SessionState());

      expect(config.cacheDir, endsWith('.kmdb_cache'));
    });

    test('cacheDir before load returns the default', () {
      // cacheDir is valid to call before load — it uses the environment default.
      final config = ReplConfig(filePath: configPath);
      expect(config.cacheDir, endsWith('.kmdb_cache'));
    });

    test('wrong type for cacheDir is ignored', () async {
      await io.File(configPath).writeAsString(jsonEncode({'cacheDir': 42}));
      final config = ReplConfig(filePath: configPath);
      await config.load(SessionState());

      // Non-string values are silently ignored — fall back to default.
      expect(config.cacheDir, endsWith('.kmdb_cache'));
    });
  });
}
