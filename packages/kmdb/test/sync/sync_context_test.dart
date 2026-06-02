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

import 'dart:async';

import 'package:kmdb/kmdb.dart';
import 'package:test/test.dart';

void main() {
  group('CancellationToken', () {
    test('isCancelled starts false', () {
      final token = CancellationToken();
      expect(token.isCancelled, isFalse);
    });

    test('isCancelled is true after cancel()', () {
      final token = CancellationToken();
      token.cancel();
      expect(token.isCancelled, isTrue);
    });

    test('cancel() is idempotent — calling twice does not throw', () {
      final token = CancellationToken();
      token.cancel();
      expect(() => token.cancel(), returnsNormally);
      expect(token.isCancelled, isTrue);
    });

    test('whenCancelled completes after cancel()', () async {
      final token = CancellationToken();
      var completed = false;
      token.whenCancelled.then((_) => completed = true);
      expect(completed, isFalse);
      token.cancel();
      // Allow microtasks to run.
      await Future<void>.value();
      expect(completed, isTrue);
    });

    test('whenCancelled on already-cancelled token completes immediately', () {
      final token = CancellationToken()..cancel();
      // A .sync() Completer completes synchronously — the future should be
      // done already. Just verify it completes without error.
      expect(token.whenCancelled, completes);
    });

    test(
      'whenCancelled can be used in Future.any to wake immediately',
      () async {
        final token = CancellationToken();
        // Use a long never-completing future alongside whenCancelled.
        final neverFuture = Completer<void>().future;
        var wakened = false;

        final raceFuture = Future.any([
          neverFuture,
          token.whenCancelled,
        ]).then((_) => wakened = true);

        expect(wakened, isFalse);
        token.cancel();
        await raceFuture;
        expect(wakened, isTrue);
      },
    );
  });

  group('SyncContext.throwIfExpired', () {
    test('does not throw when cancel is null', () {
      const ctx = SyncContext();
      expect(ctx.throwIfExpired, returnsNormally);
    });

    test('does not throw when token is not cancelled', () {
      final ctx = SyncContext(cancel: CancellationToken());
      expect(ctx.throwIfExpired, returnsNormally);
    });

    test('throws SyncCancelledException when token is cancelled', () {
      final token = CancellationToken()..cancel();
      final ctx = SyncContext(cancel: token);
      expect(ctx.throwIfExpired, throwsA(isA<SyncCancelledException>()));
    });

    test('thrown message mentions "cancelled" for a cancelled token', () {
      final token = CancellationToken()..cancel();
      final ctx = SyncContext(cancel: token);
      expect(
        () => ctx.throwIfExpired(),
        throwsA(
          isA<SyncCancelledException>().having(
            (e) => e.message.toLowerCase(),
            'message',
            contains('cancel'),
          ),
        ),
      );
    });

    test('does not throw when deadline is in the future', () {
      final ctx = SyncContext(
        deadline: DateTime.now().add(const Duration(hours: 1)),
      );
      expect(ctx.throwIfExpired, returnsNormally);
    });

    test('throws SyncCancelledException when deadline has passed', () {
      final ctx = SyncContext(
        deadline: DateTime.now().subtract(const Duration(milliseconds: 1)),
      );
      expect(ctx.throwIfExpired, throwsA(isA<SyncCancelledException>()));
    });

    test('thrown message mentions "deadline" for an expired deadline', () {
      final ctx = SyncContext(
        deadline: DateTime.now().subtract(const Duration(seconds: 1)),
      );
      expect(
        () => ctx.throwIfExpired(),
        throwsA(
          isA<SyncCancelledException>().having(
            (e) => e.message.toLowerCase(),
            'message',
            contains('deadline'),
          ),
        ),
      );
    });

    test('cancel takes priority over deadline in message', () {
      // Both conditions active: cancel message should appear (it is checked first).
      final token = CancellationToken()..cancel();
      final ctx = SyncContext(
        cancel: token,
        deadline: DateTime.now().subtract(const Duration(seconds: 1)),
      );
      expect(
        () => ctx.throwIfExpired(),
        throwsA(
          isA<SyncCancelledException>().having(
            (e) => e.message.toLowerCase(),
            'message',
            contains('cancel'),
          ),
        ),
      );
    });

    test('null context (no SyncContext) is treated as a no-op', () {
      // Simulate the common null-safe call pattern ctx?.throwIfExpired() by
      // calling through a helper so the static type is nullable at the call site.
      void callIfNonNull(SyncContext? ctx) => ctx?.throwIfExpired();
      expect(() => callIfNonNull(null), returnsNormally);
    });
  });

  group('SyncCancelledException', () {
    test('toString includes class name and message', () {
      const e = SyncCancelledException('Sync cancelled');
      expect(e.toString(), contains('SyncCancelledException'));
      expect(e.toString(), contains('Sync cancelled'));
    });

    test('can be caught as Exception', () {
      expect(
        () => throw const SyncCancelledException('test'),
        throwsA(isA<Exception>()),
      );
    });
  });
}
