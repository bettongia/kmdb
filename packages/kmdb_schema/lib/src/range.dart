// Copyright 2026 The Authors
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

/// Handy function for grabbing a [Range] and iterating over it.
///
/// ```dart
/// for (var i in range(stop: 10)) {
///   print(i);
/// }
/// ```
Iterable<num> range({
  num start = 0,
  required num stop,
  num step = 1,
  bool stopExclusive = true,
}) {
  return Range(
    start: start,
    stop: stop,
    step: step,
    stopExclusive: stopExclusive,
  ).generate();
}

/// A numerical progression.
///
/// For basic usage, just provide the (exclusive) [stop] value - note that,
/// by default, the range is _exclusive_ of the stop value:
///
/// ```dart
/// final range = Range(stop:5);
/// print(range.toList());
/// ```
///
/// Result: `[0, 1, 2, 3, 4]`
///
/// Providing a [start] value allows for a non-zero starting point:
///
/// ```dart
/// final range = Range(start: 1, stop:5);
/// print(range.toList());
/// ```
///
/// Result: `[1, 2, 3, 4]`
///
/// Consider using the [range()] function if you just want to use a one-off
/// range in a loop.
class Range {
  /// The starting value of the range (inclusive), defaults to 0
  final num start;

  /// The end value of the range (exclusive)
  final num stop;

  /// The step progression, defaults to 1. Must be greater than 0
  final num step;

  /// If false, the [stop] value is inclusive. Defaults to true
  final bool stopExclusive;

  /// Range constructor
  ///
  /// Create a range that begins at [start]. By default, [start] is 0.
  ///
  /// Ordinarily, the Range will end at [stop], exclusive of [stop].
  /// If [stopExclusive] is false, the value of [stop] is included in the range.
  ///
  /// The [step] determines the amount by which the range progresses on each
  /// iteration. By default [step] is 1.
  ///
  /// ```dart
  /// final r = range(stop: 10, step: 2);
  /// print(r.toList());
  /// ```
  ///
  /// Result: `[0, 2, 4, 6, 8]`
  ///
  /// [step] is always a positive number - an [ArgumentError] is thrown
  /// if [step] is <= 0.
  ///
  /// If the range is moving backwards (e.g. 10 -> 0), [Range] will correctly
  /// step in the reverse direction.
  ///
  /// For example, [start] at 10 and [stop] before 0, with a [step] of 2:
  ///
  /// ```dart
  /// final r = range(start: 10, stop: 0, step: 2);
  /// print(r.toList());
  /// ```
  ///
  /// Result: `[10, 8, 6, 4, 2]`
  ///
  /// To get to 0, set [stopExclusive] to `false`:
  ///
  /// ```dart
  /// final r = range(start: 10, stop: 0, step: 2, stopExclusive: false);
  /// print(r.toList());
  /// ```
  ///
  /// Result: `[10, 8, 6, 4, 2, 0]`
  Range({
    this.start = 0,
    required this.stop,
    this.step = 1,
    this.stopExclusive = true,
  }) {
    if (step <= 0) throw ArgumentError.value(step, 'step');
  }

  /// Generate all list of all values in the range.
  ///
  /// Note that this method creates a new list each call.
  /// Consider maintaining a copy of the result in your own code
  /// rather than calling [toList] multiple times.
  ///
  /// _Why not cache the result in the object?_
  /// The range could be quite large.
  List<num> toList() {
    final result = <num>[];

    for (var i in generate()) {
      result.add(i);
    }

    return result;
  }

  /// Generate the values for the range.
  ///
  /// Handy with `for` loops.
  ///
  /// Example:
  ///
  /// ```dart
  /// final list = <int>[];
  /// final range = Range(stop: 10);
  /// for (var i in range.generate()) {
  ///   list.add(i);
  /// }
  /// print(list);
  /// ```
  ///
  /// Result: `[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]`
  Iterable<num> generate() sync* {
    if (start <= stop) {
      final lastValue = stopExclusive ? stop : stop + step;
      for (num i = start; i < lastValue; i += step) {
        yield i;
      }
    } else {
      final lastValue = stopExclusive ? stop : stop - step;
      for (num i = start; i > lastValue; i -= step) {
        yield i;
      }
    }
  }

  /// True if [input] is between [start] (inclusive) and [stop].
  ///
  /// If [stopExclusive] is false, [stop] is included in the range,
  /// otherwise it is not.
  ///
  /// Note that [step] is considered in the evaluation - the [input]
  /// must be an increment of the range.
  ///
  /// As this method calls [toList], it can be expensive and you
  /// should consider caching the result of [toList] and calling
  /// that list's `contains` method.
  bool contains(num input) => toList().contains(input);

  @override
  bool operator ==(Object other) {
    if (other is Range) {
      return other.start == start &&
          other.stop == stop &&
          other.step == step &&
          other.stopExclusive == stopExclusive;
    }
    return false;
  }

  @override
  int get hashCode => Object.hash(start, stop, step, stopExclusive);

  Map<String, dynamic> toMap() => {
    'start': start,
    'stop': stop,
    'step': step,
    'stopExclusive': stopExclusive,
  };
}
