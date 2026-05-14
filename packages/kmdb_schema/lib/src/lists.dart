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

/// Return true if all items in [a] are also in [b]
///
/// This is different to `ListEquality` in the
/// [`collection`](https://pub.dev/packages/collection) package
/// as this function does not require the list elements to be in the
/// same order.
bool hasTheSameElements<T>(Iterable<T> a, Iterable<T> b) {
  if (a.length != b.length) {
    return false;
  }

  var checklist = List<bool>.filled(b.length, false, growable: false);

  for (int i = 0; i < a.length; i++) {
    var found = false;
    for (var j = 0; j < b.length; j++) {
      if (checklist[j]) continue;

      if (a.elementAt(i) == b.elementAt(j)) {
        checklist[j] = true;
        found = true;
        break;
      }
    }
    if (!found) {
      return false;
    }
  }

  return true;
}

/// Return true if [a] is a sublist of [b].
///
/// Does not care if the lists are in the same order.
bool isSubList<T>(List<T> a, List<T> b) {
  if (a.length > b.length) {
    return false;
  }

  var checklist = List<bool>.filled(b.length, false, growable: false);

  for (var i = 0; i < a.length; i++) {
    var found = false;
    for (var j = 0; j < b.length; j++) {
      if (checklist[j]) continue;

      if (a[i] == b[j]) {
        checklist[j] = true;
        found = true;
        break;
      }
    }
    if (!found) return false;
  }
  return true;
}
