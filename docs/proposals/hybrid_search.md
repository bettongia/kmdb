# Hybrid text search

Hybrid text search is activated only when both a lexical and a semantic index
are defined on a field.

## Design

The hybrid search feature does not require its own indexing infrastructure - it
is purely a ranking mechanism used to score results returned fields that are
indexed both lexically and semantically.

### Reciprocal Rank Fusion (RRF)

To combine the results of BM25 (unbounded scores) and Cosine Similarity
(normalized -1 to 1 scores), the system uses RRF. It scores based on the rank
(position) of results rather than the raw scores, making the two systems
compatible without normalisation.

Formula:

$$RRFscore(d \in D) = \sum_{r \in R} \frac{1}{k + r(d)}$$

| Symbol     | Description                                  |
| :--------- | :------------------------------------------- |
| **$d$**    | The document being evaluated.                |
| **$r(d)$** | The rank of document $d$ in a specific list. |
| **$k$**    | Smoothing constant (default = 60).           |
| **$\sum$** | Summation across all ranking systems.        |

### Candidate set size

Before RRF is applied, each index contributes a ranked candidate list. The
default candidate limit is **100 results per index**, giving a pool of up to 200
documents for fusion. This is configurable via `--candidates <n>` on the search
command; the default of 100 covers the realistic result space at kmdb's expected
scale without memory pressure.

```
kmdb <db> search <collection> "<query terms>" [--candidates 100]
```

The final result set is then reduced to `--limit` after RRF scoring.

### Candidate eligibility

Any document that scores in **either** index is included in the RRF pool — it
does not need to appear in both. A document absent from one list is treated as
having rank ∞ for that list, contributing 1/(k+∞) = 0 from it. This means
documents that score in both indexes naturally rank higher than those that score
in only one, but single-index matches are still returned rather than silently
dropped.

This guarantees correctness in partial-index states — for example, if the
semantic index was added after some documents were written and the index has not
yet been fully rebuilt, those documents still appear in results via their BM25
score alone rather than being suppressed.

### CLI

The `search` command accepts a `--mode` flag to control which index (or
combination of indexes) is used for ranking:

```
kmdb <db> search <collection> "<query terms>" [--mode auto|lexical|semantic]
```

| Mode         | Behaviour                                                                 |
| :----------- | :------------------------------------------------------------------------ |
| `auto`       | Default. Uses hybrid RRF if both indexes exist on the searched fields; falls back to whichever single index is available. |
| `lexical`    | BM25 only. Returns an error if no lexical index exists on the field.      |
| `semantic`   | Cosine similarity only. Returns an error if no semantic index exists on the field. |

The `auto` mode allows users to add a second index later without changing their
queries. The explicit modes are useful for debugging, benchmarking, or cases
where one ranking approach is known to be more appropriate for the query type.

## Open Questions
