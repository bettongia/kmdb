/*
 Copyright 2024 The KMDB Authors

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

/// The exception case
final class Failure<T, E extends Exception> extends Result<T, E> {
  final E _exception;
  const Failure(this._exception);

  @override
  E? get exception => _exception;

  @override
  bool get isFailure => true;

  @override
  bool get isSuccess => false;

  @override
  T? get value => null;

  @override
  Result<T, E> onFailure(void Function(E exception) error) {
    error(_exception);
    return this;
  }

  @override
  Result<T, E> onSuccess(void Function(T value) success) {
    return this;
  }
}

/// Model for returning a result without throwing exceptions.
///
/// Presents a model for error handling that avoids the use of
/// `try`/`catch` blocks. Core to the idea is that underlying
/// libraries should provide a model for error handling that
/// lets the calling application determine if an exception needs
/// to be raised.
///
/// ## Example usage
///
/// ```dart
/// import 'package:aurochs_core/core.dart';
///
/// class DivideByZero implements Exception {
///   @override
///   String toString() => 'Cannot divide by zero';
/// }
///
/// Result<int, DivideByZero> divide(int a, int b) {
///   if (b == 0) {
///     return Failure(DivideByZero());
///   }
///   return Success(a ~/ b);
/// }
///
/// void main() {
///
///   print('Handle the result using switch:');
///   switch (divide(10, 2)) {
///     case Success(:var value):
///       print('Success (10 / 2): $value');
///     case Failure(:var exception):
///       print('Failure (10 / 2): $exception');
///   }
///
///   switch (divide(10, 0)) {
///     case Success(:var value):
///       print('Success (10 / 0): $value');
///     case Failure(:var exception):
///       print('Failure (10 / 0): $exception');
///   }
///   print('---');
///
///   print('Handle the result in a "functional" way:');
///   divide(10, 2)
///       .onSuccess((int result) => print('  - Success (10 / 2): $result'));
///   divide(10, 0)
///       .onFailure((DivideByZero e) => print('  - Failure (10 / 0): $e'));
///
///   print('---');
///
///   print('Handle the result using if/else:');
///   final result = divide(10, 3);
///   if (result.isFailure) {
///     print('  - Failure (10 / 3): ${result.exception}');
///   } else {
///     print('  - Success (10 / 3): ${result.value}');
///   }
///   print('---');
///
///   print('Throw then catch the error via onFailure:');
///   try {
///     divide(10, 0).onFailure((DivideByZero e) => throw e);
///   } on DivideByZero catch (e) {
///     print('  - Failure (10 / 0): $e');
///   }
///   print('---');
///
///   print('Throw the error via the Failure result:');
///   final result2 = divide(10, 0);
///   if (result2.isFailure) {
///     print('  - Failure (10 / 0): About to throw an exception:');
///     throw result2.exception!;
///   }
/// }
/// ```
sealed class Result<T, E extends Exception> {
  const Result();

  /// Returns the exception if the result is a failure
  E? get exception;

  /// Returns true if the result is a failure
  bool get isFailure;

  /// Returns true if the result is a success
  bool get isSuccess;

  /// Returns the value if the result is a success
  T? get value;

  /// Handle a failure result
  ///
  /// ```dart
  /// divide(10, 0).onFailure((DivideByZero e) => print('Error: $e'));
  /// ```
  Result<T, E> onFailure(void Function(E exception) error);

  /// Handle a success result
  ///
  /// ```dart
  /// divide(10, 2).onSuccess((int result) => print('Result: $result'));
  /// ```
  Result<T, E> onSuccess(void Function(T value) success);
}

/// The success case
final class Success<T, E extends Exception> extends Result<T, E> {
  final T _value;
  const Success(this._value);

  @override
  E? get exception => null;

  @override
  bool get isFailure => false;

  @override
  bool get isSuccess => true;

  @override
  T? get value => _value;

  @override
  Result<T, E> onFailure(void Function(E exception) error) {
    return this;
  }

  @override
  Result<T, E> onSuccess(void Function(T value) success) {
    success(_value);
    return this;
  }
}
