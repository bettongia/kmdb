#!/usr/bin/env python3
# Copyright 2026 The KMDB Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import csv
import json
import sys

input = sys.argv[1]
if input == "":
    sys.exit("input file is required")

dialect = csv.excel
has_header = False
data = []

with open(input, newline='') as csvfile:

    dialect = csv.Sniffer().sniff(csvfile.read(1024))
    csvfile.seek(0)
    has_header = csv.Sniffer().has_header(csvfile.read(1024))
    csvfile.seek(0)


    reader = csv.reader(csvfile, dialect)

    for row in reader:
        data.append(row)

if not has_header:
    sys.exit("I need a header row")

headers = data[0]
result = [dict(zip(headers, row)) for row in data[1:]]

for r in result:
    print(json.dumps(r))
