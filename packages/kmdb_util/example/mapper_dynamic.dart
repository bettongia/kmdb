// Copyright 2026 The KMDB Authors
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

import 'package:kmdb_util/util.dart';

class Person implements MappedObject {
  final String name;
  final int age;

  Person(this.name, this.age);

  @override
  Map<String, dynamic> toMap() => {'name': name, 'age': age};
}

void main() {
  final person = Person('Fred', 42);

  print(person.toMap());
}
