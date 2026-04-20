// Copyright 2024 The KMDB Authors.
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

import 'package:kmdb_util/util.dart';
import 'package:test/test.dart';

Result<bool, Exception> returnSuccess() {
  return Success(true);
}

Result<bool, Exception> returnError() {
  return Failure(Exception('error'));
}

void main() {
  test('Test a successful call', () async {
    expect(returnSuccess().isSuccess, true);
  });

  test('Test a successful call with when', () async {
    returnSuccess()
        .onSuccess((value) => expect(value, true))
        .onFailure((e) => expect(e, isNot(isException)));
  });

  test('Test a successful call with when using ..', () async {
    returnSuccess()
      ..onSuccess((value) => expect(value, true))
      ..onFailure((e) => expect(e.toString(), ''));
  });

  test('Test a failed call', () async {
    expect(returnError().isSuccess, false);
  });

  test('Test a failed call with when', () async {
    returnError()
        .onSuccess((value) => expect(value, isNull))
        .onFailure((e) => expect(e.toString(), 'Exception: error'));
  });

  test('Test a failed call with when using ..', () async {
    returnError()
      ..onSuccess((value) => expect(value, isNull))
      ..onFailure((e) => expect(e.toString(), 'Exception: error'));
  });

  test('Test a failed call using isSuccess and isFailure', () async {
    final result = returnError();
    expect(result.isSuccess, false);
    expect(result.isFailure, true);
  });

  test('Test a successful call using isSuccess and isFailure', () async {
    final result = returnSuccess();
    expect(result.isSuccess, true);
    expect(result.isFailure, false);
  });
}
