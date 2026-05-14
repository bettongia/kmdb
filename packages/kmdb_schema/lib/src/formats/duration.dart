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

/// Duration ala ISO 8601.
///
/// This is a purposefully simple implementation and is not intended
/// to provide DateTime-style functionality. The main issues is that
/// having [months] and [years] makes the duration contextual and we
/// can't then boil it down to seconds (e.g. _how many seconds in a
/// month?_).
///
/// From my reading of Appendix A of RFC 3339, negative values are
/// not allowed.
///
/// See:
///
///  - [Appendix A of RFC 3339](https://www.rfc-editor.org/info/rfc3339)
///  - [Wikipedia](https://en.wikipedia.org/wiki/ISO_8601#Durations)
final RegExp iso8601Duration = RegExp(
  r'^P'
  r'((?<years>\d+)Y)?'
  r'((?<months>\d+)M)?'
  r'((?<days>\d+)D)?'
  r'(T'
  r'((?<hours>\d+)H)?'
  r'((?<minutes>\d+)M)?'
  r'((?<seconds>\d+)S)?)?$',
);

/// Parse an ISO 8601 duration [value] string into a [Iso8601Duration].
///
/// [maxInputLength] is the maximum number of [value] characters
///
/// Examples:
///
///   - `P1S` - One second
///   - `P1M` - One month
///   - `P1MT1M` - One month and one minute
///   - `P1Y2M3DT4H5M6S` - One year, two months, three days, four hours, five minutes, six seconds
///
/// Returns (null, false) if the [value] is not a valid duration.
bool isValidDuration(String value, {int maxInputLength = 24}) {
  // Guard the RegEx from dodgy strings
  if (value.substring(0, 1) != 'P' ||
      value.length > maxInputLength ||
      [
        'Y',
        'M',
        'D',
        'H',
        'S',
        'T',
      ].contains(value.substring(value.length - 2))) {
    return false;
  }

  var match = iso8601Duration.firstMatch(value);
  if (match == null) {
    return false;
  }

  int? seconds = int.tryParse(match.namedGroup('seconds') ?? '0');
  int? minutes = int.tryParse(match.namedGroup('minutes') ?? '0');
  int? hours = int.tryParse(match.namedGroup('hours') ?? '0');
  int? days = int.tryParse(match.namedGroup('days') ?? '0');
  int? months = int.tryParse(match.namedGroup('months') ?? '0');
  int? years = int.tryParse(match.namedGroup('years') ?? '0');

  if ([seconds, minutes, hours, days, months, years].any((e) => e == null)) {
    return false;
  }

  return true;
}
