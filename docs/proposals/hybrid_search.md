# Hybrid text search

#### D.1 Reciprocal Rank Fusion (RRF)

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

> **[Review]:** RRF is a solid, well-tested choice. A few considerations:
>
> 1. Documents that appear in only one ranked list (e.g. a purely semantic match
>    with no lexical overlap) still receive an RRF score. Is that the intended
>    behaviour, or should there be a minimum-score threshold?
> 2. How does RRF interact with the existing `KmdbQuery` filter DSL? For
>    example, if a user wants `where('tags').containsAll(['dart'])` combined
>    with a full-text search, how are the filter results intersected with the
>    RRF ranked list?
> 3. Consider exposing a `searchMode` option: `lexical`, `semantic`, or
>    `hybrid`, allowing callers to opt out of the full pipeline when only one
>    approach is needed (important for devices where the embedding model is not
>    loaded).

#### D.2 Open Questions for Phase D

7. **API surface:** How does search integrate with the existing
   `KmdbCollection<T>` query API? Does `KmdbQuery` gain a
   `.search(String query)` terminal, or is there a separate
   `KmdbCollection.search()` method that returns ranked results outside the
   filter/orderBy pipeline? Results ranked by RRF are not naturally composable
   with `orderBy`.
