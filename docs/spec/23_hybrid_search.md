# Hybrid Search

## Purpose

Hybrid search combines the results of a lexical search (BM25, §21) and a
semantic search (cosine similarity, §22) on the same field using Reciprocal
Rank Fusion (RRF). It activates automatically when both a lexical and a semantic
index exist on the field being searched (`SearchMode.auto`).

Hybrid search requires no additional index infrastructure — it is purely a
ranking step applied to candidate sets returned by the two existing indexes.

## Reciprocal Rank Fusion

RRF scores documents by their rank position across the two result lists rather
than by their raw scores, making BM25 (unbounded) and cosine similarity
(−1 to 1) compatible without normalisation:

$$\text{RRF}(d) = \sum_{r \in R} \frac{1}{k + r(d)}$$

| Symbol     | Meaning                                                   |
| :--------- | :-------------------------------------------------------- |
| $d$        | The document being scored.                                |
| $R$        | The set of ranked result lists (BM25 list, cosine list).  |
| $r(d)$     | 1-based rank of document $d$ in list $r$.                 |
| $k$        | Smoothing constant (default 60). Configurable per index.  |

A document absent from one list is treated as having rank $\infty$ for that
list, contributing $1/(k + \infty) = 0$ from it.

## Candidate Set

Before RRF is applied, each index contributes a ranked candidate list. The
default candidate limit is **100 results per index** (200 candidates total).
This is configurable via `--candidates <n>` on the CLI search command and an
equivalent `candidates` parameter on the Dart `search()` call.

The final result set is reduced to `--limit` after RRF scoring.

## Candidate Eligibility

Any document that scores in **either** index is included in the RRF pool — it
does not need to appear in both. Documents that score in both indexes naturally
rank higher than those that score in only one; single-index matches are still
returned rather than silently dropped.

This guarantees correctness in partial-index states. For example, if the
semantic index was added after some documents were written and the index build
has not completed, those documents still appear in results via their BM25 score
alone.

## Mode Flag

The `--mode` flag (CLI) and `SearchMode` parameter (Dart API) control which
index is used. See §20 for the full mode table. The `auto` default means users
can add a second index at any time without changing existing queries.

## Score Structure

In hybrid mode, `SearchHit.score` holds the document's overall RRF score.
`SearchHit.fieldScores` carries per-field scores keyed as follows:

| Key                  | Value                          |
| :------------------- | :----------------------------- |
| `"{field}"`          | Per-field RRF score            |
| `"{field}:bm25"`     | Per-field BM25 score (lexical) |
| `"{field}:cosine"`   | Per-field cosine similarity    |

Fields where the document did not score in a given mode are absent from the map.
For example, a document found only via BM25 will have `"description:bm25"` but
no `"description:cosine"` key.
