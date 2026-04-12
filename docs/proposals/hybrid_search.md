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

Document fields that are indexed with only a lexical or a semantic index will
not be given an RRF score.

### CLI

If a field is indexed both by the lexical and semantic approaches, results from
the `search` command will return the hybrid search result. No option will be
made available to select a specific index.

## Open Questions
