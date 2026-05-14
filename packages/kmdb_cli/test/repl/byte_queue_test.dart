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

import 'package:kmdb_cli/src/repl/input_reader.dart';
import 'package:test/test.dart';

void main() {
  group('ByteQueue', () {
    group('next()', () {
      test('returns a byte that was added before next() was called', () async {
        final q = ByteQueue();
        q.add(0x41);
        expect(await q.next(), 0x41);
      });

      test(
        'waits for a byte when the queue is empty, then returns it',
        () async {
          final q = ByteQueue();
          // Schedule the add after next() starts waiting.
          Future.microtask(() => q.add(0x42));
          expect(await q.next(), 0x42);
        },
      );

      test('returns bytes in FIFO order when multiple are enqueued', () async {
        final q = ByteQueue();
        q.add(0x01);
        q.add(0x02);
        q.add(0x03);
        expect(await q.next(), 0x01);
        expect(await q.next(), 0x02);
        expect(await q.next(), 0x03);
      });

      test(
        'returns EOF sentinel (0x04) when closed with no pending bytes',
        () async {
          final q = ByteQueue();
          q.close();
          expect(await q.next(), 0x04);
        },
      );

      test(
        'returns pending bytes before the EOF sentinel after close()',
        () async {
          final q = ByteQueue();
          q.add(0x61);
          q.add(0x62);
          q.close();
          expect(await q.next(), 0x61);
          expect(await q.next(), 0x62);
          expect(await q.next(), 0x04);
        },
      );

      test(
        'returns EOF sentinel when closed while a waiter is pending',
        () async {
          final q = ByteQueue();
          final future = q.next();
          q.close();
          expect(await future, 0x04);
        },
      );

      test('close() is idempotent', () async {
        final q = ByteQueue();
        q.close();
        q.close(); // must not throw
        expect(await q.next(), 0x04);
      });
    });

    group('nextTimeout()', () {
      test('returns a byte that was already enqueued', () async {
        final q = ByteQueue();
        q.add(0x78);
        expect(await q.nextTimeout(const Duration(milliseconds: 50)), 0x78);
      });

      test('returns null when the timeout elapses with no byte', () async {
        final q = ByteQueue();
        final result = await q.nextTimeout(const Duration(milliseconds: 10));
        expect(result, isNull);
      });

      test('returns a byte delivered before the timeout expires', () async {
        final q = ByteQueue();
        Future.delayed(const Duration(milliseconds: 5), () => q.add(0x79));
        expect(await q.nextTimeout(const Duration(milliseconds: 200)), 0x79);
      });

      test('returns null when closed with no pending bytes', () async {
        final q = ByteQueue();
        q.close();
        expect(await q.nextTimeout(const Duration(milliseconds: 50)), isNull);
      });

      test('allows another next() call after a timeout', () async {
        final q = ByteQueue();
        // First call times out.
        expect(await q.nextTimeout(const Duration(milliseconds: 10)), isNull);
        // Queue is still usable.
        q.add(0x7a);
        expect(await q.next(), 0x7a);
      });
    });

    group('add() after close()', () {
      test('bytes added after close() are silently discarded', () async {
        final q = ByteQueue();
        q.close();
        q.add(0x41); // should not throw
        expect(await q.next(), 0x04);
      });
    });
  });
}
