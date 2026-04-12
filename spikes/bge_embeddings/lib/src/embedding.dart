// Copyright 2026 The Aurochs KMesh Authors
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

import 'ort_library.dart';
import 'ort_session.dart';
import 'tokenizer.dart';
import 'math_utils.dart';

class BgeEmbedder {
  final OrtInferenceSession _session;
  final BertTokenizer _tokenizer;

  BgeEmbedder._(this._session, this._tokenizer);

  /// Load the model. Downloads the ORT native library automatically if needed.
  static Future<BgeEmbedder> load({
    required String modelPath,
    required String vocabPath,
    int maxLength = 512,
  }) async {
    final lib = await openOrtLibrary();
    final session = OrtInferenceSession.create(lib, modelPath);
    final tokenizer = await BertTokenizer.load(vocabPath, maxLength: maxLength);
    return BgeEmbedder._(session, tokenizer);
  }

  /// Embed a single string. Returns a normalized 384-dim vector.
  /// Synchronous — call from a background isolate for large batches.
  List<double> embed(String text) {
    final tokens = _tokenizer.encode(text);
    final raw = _session.run(
      inputNames: ['input_ids', 'attention_mask', 'token_type_ids'],
      inputData: [tokens.inputIds, tokens.attentionMask, tokens.tokenTypeIds],
      inputShape: [1, tokens.inputIds.length],
      outputName: 'last_hidden_state',
    );
    return l2Normalize(
      meanPool(
        raw,
        tokens.attentionMask.toList(),
        seqLen: tokens.inputIds.length,
      ),
    );
  }

  /// Embed multiple texts. ORT sessions are thread-affine — running inference
  /// via [Isolate.run] causes ORT's internal thread-pool to tear down when the
  /// spawned thread exits, corrupting shared mutex state. Keep all ORT calls on
  /// the same thread that created the session.
  List<List<double>> embedAll(List<String> texts) =>
      texts.map(embed).toList();

  void dispose() => _session.dispose();
}
