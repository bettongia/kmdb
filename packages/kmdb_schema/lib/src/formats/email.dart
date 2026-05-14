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

const _localPartRegex = r"(?<localPart>[a-zA-Z0-9.!#$%&'*+\/=?^_`{|}~-]+)";

const _domainRegex =
    r"(?<domain>[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*)";

const _addrSpec = '$_localPartRegex@$_domainRegex';

final _emailRegex = RegExp('^$_addrSpec\$');

/// Parse [value], returning a valid email address.
///
/// This is based on the HTML Living Standard, section 4.10.5 The input element.
///
/// See: https://html.spec.whatwg.org/multipage/input.html#email-state-(type=email)
///
/// The approach is a pragmatic subset of RFC 5322.
bool isValidEmail(String value, {int maxInputLength = 30}) {
  if (value.length > maxInputLength) {
    return false;
  }

  var match = _emailRegex.firstMatch(value);
  if (match == null) {
    return false;
  }
  var localPart = match.namedGroup('localPart');
  var domain = match.namedGroup('domain');

  if (localPart == null || domain == null) {
    return false;
  }
  return true;
}
