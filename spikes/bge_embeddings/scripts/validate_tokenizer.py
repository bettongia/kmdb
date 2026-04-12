# Copyright 2026 The KMDB Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# validate_tokenizer.py
from transformers import AutoTokenizer
tok = AutoTokenizer.from_pretrained("BAAI/bge-small-en-v1.5")
enc = tok("What is the effect of temperature on enzyme activity?",
          max_length=512, truncation=True, padding="max_length")
print("input_ids[:10]     :", enc["input_ids"][:10])
print("attention_mask[:10]:", enc["attention_mask"][:10])
