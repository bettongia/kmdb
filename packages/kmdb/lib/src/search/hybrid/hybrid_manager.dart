// Copyright 2026 The KMDB Authors.
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

import '../search_result.dart';

/// Computes the Reciprocal Rank Fusion (RRF) score for a single ranked list.
///
/// The formula is `1.0 / (k + rank)` where [rank] is 1-based (1 = best).
/// The smoothing constant [k] prevents very high scores for top-ranked
/// documents when the list is short. The default value of 60 is from the
/// original RRF paper (Cormack et al. 2009).
///
/// Throws [ArgumentError] if [k] < 1 (k == 0 would cause division by zero
/// at rank == 0, and negative values produce nonsensical negative scores).
///
/// ```dart
/// final score = rrfScore(1); // 1.0 / (60 + 1) ≈ 0.01639
/// ```
double rrfScore(int rank, {int k = 60}) {
  if (k < 1) throw ArgumentError.value(k, 'k', 'rrfK must be >= 1');
  return 1.0 / (k + rank);
}

/// Merges lexical (BM25) and semantic (cosine) hit lists using Reciprocal
/// Rank Fusion (RRF).
///
/// ## RRF formula
///
/// For each document `d`, its overall score is the sum of its RRF contribution
/// from each ranked list it appears in:
///
/// ```
/// RRF(d) = Σ_{r ∈ R} 1 / (rrfK + rank_r(d))
/// ```
///
/// A document absent from one list contributes 0 from that list (treating its
/// rank in that list as ∞). This ensures single-index matches are not silently
/// dropped in partial-index states.
///
/// ## fieldScores key structure
///
/// In the returned [SearchHit.fieldScores] map:
///
/// - `"{field}:bm25"` → the raw BM25 score from the lexical hit (absent if the
///   document was not in [lexicalHits] for that field).
/// - `"{field}:cosine"` → the raw cosine similarity from the semantic hit
///   (absent if the document was not in [semanticHits] for that field).
/// - `"{field}"` → the per-field RRF score contribution (sum of each list's
///   `1 / (rrfK + rank)` for this document and field).
///
/// ## Parameters
///
/// - [lexicalHits] — ranked list from [FtsManager.search], ordered by
///   descending BM25 score. Each hit's [SearchHit.fieldScores] must use the
///   `"{field}:bm25"` key convention produced by [FtsManager].
/// - [semanticHits] — ranked list from [VecManager.search], ordered by
///   descending cosine similarity. Each hit's [SearchHit.fieldScores] must
///   use the `"{field}:cosine"` key convention produced by [VecManager].
/// - [limit] — maximum hits to include in the returned result.
/// - [offset] — number of top results to skip (for pagination).
/// - [metadata] — the [SearchMetadata] to attach to the returned
///   [SearchResult]. Callers construct this from the union of searched and
///   skipped fields across both legs.
/// - [rrfK] — the RRF smoothing constant (default 60). Must be >= 1.
///
/// ## Multi-field queries
///
/// When multiple fields are searched, each leg returns per-field scores via
/// [SearchHit.fieldScores]. The RRF merge treats each document's contribution
/// from each list globally (not per-field) — rank in the lexical list is the
/// document's position across all fields, and similarly for the semantic list.
/// Per-field component scores are preserved in [SearchHit.fieldScores] for
/// transparency.
///
/// The overall [SearchHit.score] is the per-document RRF score computed from
/// the document's rank in each list.
///
/// ## Tie-breaking
///
/// Documents with identical RRF scores are ordered lexicographically by their
/// [SearchHit.id] (ascending), ensuring stable, reproducible output.
///
/// ## Empty results
///
/// If both [lexicalHits] and [semanticHits] are empty, an empty [SearchResult]
/// is returned (not an error).
///
/// Throws [ArgumentError] if [rrfK] < 1.
SearchResult<T> mergeWithRrf<T>({
  required List<SearchHit<T>> lexicalHits,
  required List<SearchHit<T>> semanticHits,
  required int limit,
  required int offset,
  required SearchMetadata metadata,
  int rrfK = 60,
}) {
  if (rrfK < 1) throw ArgumentError.value(rrfK, 'rrfK', 'rrfK must be >= 1');

  // Short-circuit: both lists empty → empty result.
  if (lexicalHits.isEmpty && semanticHits.isEmpty) {
    return SearchResult<T>(
      metadata: SearchMetadata(
        query: metadata.query,
        searched: metadata.searched,
        skipped: metadata.skipped,
        total: 0,
      ),
      hits: const [],
    );
  }

  // ── Step 1: Index documents by id from each list ─────────────────────────
  // Map from docId → the SearchHit from each leg.
  final lexicalById = <String, SearchHit<T>>{};
  for (final hit in lexicalHits) {
    lexicalById[hit.id] = hit;
  }

  final semanticById = <String, SearchHit<T>>{};
  for (final hit in semanticHits) {
    semanticById[hit.id] = hit;
  }

  // Union of all document ids encountered across both lists.
  final allIds = {...lexicalById.keys, ...semanticById.keys};

  // ── Step 2: Build per-document RRF scores ────────────────────────────────
  // Compute the 1-based rank for each document in each list.
  final lexicalRank = <String, int>{};
  for (var i = 0; i < lexicalHits.length; i++) {
    lexicalRank[lexicalHits[i].id] = i + 1;
  }

  final semanticRank = <String, int>{};
  for (var i = 0; i < semanticHits.length; i++) {
    semanticRank[semanticHits[i].id] = i + 1;
  }

  // Build a list of (docId, rrfScore) pairs.
  final scored = <({String docId, double score})>[];

  for (final docId in allIds) {
    double docRrf = 0.0;

    final lRank = lexicalRank[docId];
    if (lRank != null) {
      // Document appeared in the lexical list: add its RRF contribution.
      docRrf += 1.0 / (rrfK + lRank);
    }

    final sRank = semanticRank[docId];
    if (sRank != null) {
      // Document appeared in the semantic list: add its RRF contribution.
      docRrf += 1.0 / (rrfK + sRank);
    }

    scored.add((docId: docId, score: docRrf));
  }

  // Sort descending by RRF score; use docId as a stable tiebreaker.
  scored.sort((a, b) {
    final cmp = b.score.compareTo(a.score);
    return cmp != 0 ? cmp : a.docId.compareTo(b.docId);
  });

  final total = scored.length;

  // ── Step 3: Apply pagination and build SearchHit list ────────────────────
  final page = scored.skip(offset).take(limit);

  final hits = <SearchHit<T>>[];
  var rank = offset + 1;

  for (final entry in page) {
    final docId = entry.docId;
    final lexHit = lexicalById[docId];
    final vecHit = semanticById[docId];

    // Choose the document value from whichever leg has it.
    // Both legs always carry the same document object, so either is fine.
    final document = (lexHit ?? vecHit)!.document;

    // ── Step 4: Merge fieldScores ────────────────────────────────────────
    // Start with the raw component scores from both hits.
    final fieldScores = <String, double>{};

    if (lexHit != null) {
      // Include all BM25 field scores from the lexical hit.
      // Keys follow the "{field}:bm25" convention from FtsManager.
      fieldScores.addAll(lexHit.fieldScores);
    }

    if (vecHit != null) {
      // Include all cosine field scores from the semantic hit.
      // Keys follow the "{field}:cosine" convention from VecManager.
      fieldScores.addAll(vecHit.fieldScores);
    }

    // Derive the set of field names that contributed scores to this document.
    // A field is present if it appears as a suffix in either hit's fieldScores.
    // We add a per-field RRF score key ("{field}") representing the overall
    // RRF contribution for that field in this document.
    //
    // Since RRF merges at the document level (not per-field), the per-field
    // RRF score equals the document-level RRF score when all fields use the
    // same rank lists. For multi-field transparency we record the same
    // document-level RRF score under each field key.
    final fieldNames = <String>{};
    for (final key in fieldScores.keys) {
      // Extract the field name from keys like "title:bm25" or "body:cosine".
      final colonIdx = key.lastIndexOf(':');
      if (colonIdx > 0) {
        fieldNames.add(key.substring(0, colonIdx));
      }
    }

    for (final field in fieldNames) {
      fieldScores[field] = entry.score;
    }

    hits.add(
      SearchHit<T>(
        rank: rank++,
        score: entry.score,
        fieldScores: fieldScores,
        id: docId,
        document: document,
      ),
    );
  }

  return SearchResult<T>(
    metadata: SearchMetadata(
      query: metadata.query,
      searched: metadata.searched,
      skipped: metadata.skipped,
      total: total,
    ),
    hits: hits,
  );
}
