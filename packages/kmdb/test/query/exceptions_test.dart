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

import 'package:kmdb/src/query/exceptions.dart';
import 'package:test/test.dart';

void main() {
  group('DocumentAlreadyExistsException', () {
    test('toString includes key and namespace', () {
      const e = DocumentAlreadyExistsException('key-abc', 'contacts');
      final s = e.toString();
      expect(s, contains('key-abc'));
      expect(s, contains('contacts'));
    });

    test('is an Exception', () {
      expect(
        const DocumentAlreadyExistsException('k', 'ns'),
        isA<Exception>(),
      );
    });
  });

  group('DocumentNotFoundException', () {
    test('toString includes key and namespace', () {
      const e = DocumentNotFoundException('key-xyz', 'tasks');
      final s = e.toString();
      expect(s, contains('key-xyz'));
      expect(s, contains('tasks'));
    });

    test('is an Exception', () {
      expect(const DocumentNotFoundException('k', 'ns'), isA<Exception>());
    });
  });

  group('StaleIndexException', () {
    test('toString includes namespace, path, and status', () {
      const e = StaleIndexException(
        namespace: 'contacts',
        path: 'address.city',
        status: 'stale',
      );
      final s = e.toString();
      expect(s, contains('contacts'));
      expect(s, contains('address.city'));
      expect(s, contains('stale'));
    });

    test('is an Exception', () {
      expect(
        const StaleIndexException(
          namespace: 'ns',
          path: 'p',
          status: 'stale',
        ),
        isA<Exception>(),
      );
    });
  });

  group('ReservedFieldException', () {
    test('toString includes all offending keys', () {
      const e = ReservedFieldException(['_id', '_rev']);
      final s = e.toString();
      expect(s, contains('_id'));
      expect(s, contains('_rev'));
    });

    test('single offending key', () {
      const e = ReservedFieldException(['_hidden']);
      expect(e.toString(), contains('_hidden'));
    });

    test('is an Exception', () {
      expect(const ReservedFieldException(['_x']), isA<Exception>());
    });
  });

  group('ReservedIndexPathException', () {
    test('toString includes namespace and path', () {
      const e = ReservedIndexPathException('users', '_id');
      final s = e.toString();
      expect(s, contains('users'));
      expect(s, contains('_id'));
    });

    test('is an Exception', () {
      expect(
        const ReservedIndexPathException('ns', '_p'),
        isA<Exception>(),
      );
    });
  });

  group('SchemaValidationException', () {
    test('toString includes collection name', () {
      final e = SchemaValidationException(
        collection: 'orders',
        violations: const [
          SchemaViolation(path: 'amount', message: 'must be positive'),
        ],
      );
      final s = e.toString();
      expect(s, contains('orders'));
    });

    test('toString includes violation messages', () {
      final e = SchemaValidationException(
        collection: 'orders',
        violations: const [
          SchemaViolation(path: 'amount', message: 'must be positive'),
          SchemaViolation(path: 'name', message: 'is required'),
        ],
      );
      final s = e.toString();
      expect(s, contains('must be positive'));
      expect(s, contains('is required'));
    });

    test('is an Exception', () {
      expect(
        SchemaValidationException(
          collection: 'ns',
          violations: const [],
        ),
        isA<Exception>(),
      );
    });
  });

  group('IndexRebuildEvent', () {
    test('toString includes namespace and path', () {
      const e = IndexRebuildEvent(namespace: 'posts', path: 'title');
      final s = e.toString();
      expect(s, contains('posts'));
      expect(s, contains('title'));
    });
  });
}
