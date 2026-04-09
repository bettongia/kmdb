# Technical Proposal: Hybrid Text Search Engine

## 1. Executive Summary

This proposal outlines the architecture for a hybrid search engine for the kmdb
database.

## 2. Core Search Pillars & Algorithms

To achieve good results, the system fuses two distinct
mathematical approaches into a single ranked list.

### 2.1 Lexical Search (Keyword)

Lexical search handles exact matches, specific technical identifiers (e.g.,
0x8004210B, mTLS), and "search-as-you-type" functionality.

#### Primary Structure

A Radix Tree (Compact Trie) is to be considered as a standard Trie is avoided
due to high memory overhead. The Radix Tree compresses edges where a node has
only one child, significantly reducing the number of objects in the Dart heap.

- Search Complexity: O(m) where m is the length of the search string.
- Memory Benefit: Common technical prefixes (e.g., com.google.devtools...) are
  stored only once.

However, kmdb is designed to operate across mobile and web platforms that have
constrained memory footprints. Further research is needed to understand the
options available for effective keyword searches.

#### Ranking Algorithm

BM25 (Best Matching 25) BM25 calculates relevance by looking at term frequency
(tf) and inverse document frequency (idf), while adjusting for document
length.Formula:

- IDF(q_i): Logarithmic scale of how rare the term is across the dataset.
- f(q_i, D): Number of times term i appears in document D.
- |D| / avgdl: Normalization factor to prevent long documents from ranking
  higher simply by containing more words.

### 2.2 Semantic Search (Vector)

Semantic search handles "intent" and "themes," allowing a search for "memory
leak" to find documents discussing "garbage collection issues" even if the words
don't match.

Primary Structure: Dense Vectors Text is converted into floating-point arrays
(embeddings) using a local transformer model such as Gemma 4, hosted using the
LiteRT framework.

Similarity Metric: Cosine Similarity Measures the cosine of the angle between
the query vector ($A$) and the document vector ($B$).

$$\text{similarity} = \cos(\theta) = \frac{\sum_{i=1}^{n} A_i B_i}{\sqrt{\sum_{i=1}^{n} A_i^2} \sqrt{\sum_{i=1}^{n} B_i^2}}$$

### 2.3 Hybrid Fusion: Reciprocal Rank Fusion (RRF)

To combine the results of BM25 (unbounded scores) and Cosine Similarity
(normalized -1 to 1 scores), the system uses RRF. It scores based on the rank
(position) of results.

Formula:

$$RRFscore(d \in D) = \sum_{r \in R} \frac{1}{k + r(d)}$$

| Symbol     | Description                                  |
| :--------- | :------------------------------------------- |
| **$d$**    | The document being evaluated.                |
| **$r(d)$** | The rank of document $d$ in a specific list. |
| **$k$**    | Smoothing constant (default = 60).           |
| **$\sum$** | Summation across all ranking systems.        |

## 3. Local Embedding Models & Inference

For local execution, the "Encoder" portion of a transformer model is used via
[LiteRT](https://ai.google.dev/edge/litert). This will allow for the initial use
of a model such as Gemma but also for "swapping in" other models at a future
date. This will need FFI work to create a Dart library that interfaces with
LiteRT.

### 3.1 Optimization: Matryoshka & Quantization

There are a few optimisation approaches to consider:

- [Matryoshka Embeddings](https://arxiv.org/abs/2205.13147): Allows truncating
  768d vectors to 128d with \<2% accuracy loss, reducing memory usage by 6x.
- Scalar Quantization (SQ8): Converts 32-bit floats to 8-bit integers. This
  allows for SIMD (Single Instruction, Multiple Data) acceleration on ARM/x86
  CPUs.

See also:
[Vector Quantization Survey and Selection Guide](https://doris.apache.org/docs/dev/ai/vector-search/quantization-survey)

## 4. Cross-Platform Strategy

As kmdb is designed to operate across mobile, web and desktop platforms, and
that the database is not expected to be large, it is likely that the "Flat
Index + SQ8" approach will provide the best approach.

Further investigation is needed.

### Comparison

| Platform | Vector Indexing Algorithm | Rationale                                                                                                                 |
| :------- | :------------------------ | :------------------------------------------------------------------------------------------------------------------------ |
| Mobile   | Flat Index + SQ8          | At \<50k items, brute-force scanning quantized vectors is faster and more battery-efficient than building complex graphs. |
| Desktop  | HNSW (Graph-based)        | Fast O(log n) retrieval. Desktop RAM allows for the high memory overhead of the hierarchical graph.                       |
| Web      | IVF-Flat (Clustering)     | Groups vectors into clusters. Only searches the N closest clusters to keep the main thread responsive.                    |

## 5. Other items

The existence of a model such as Gemma in the distribution opens up addition
feature possibilities, including:

- The ability to summarise documents stored in the [vault](vault.md)
- Processing PDF documents to obtain plain text for use in the search indexes
- Providing an agent to help answer questions

## 6. Open questions

1. As the keyword and vector indexes can be expensive to create do we need to
   consider an approach where the indexes are synchronised so that other devices
   don't need to generate the index locally?
2. Can these index types be useful in a lazy, "build on first query" approach?
   1. Rebuilding the index will be very inefficient
3. Should the vectors be stored using the [vault](vault.md) rather than in the
   KV/Storage Engine?
4. Can users opt out of either type of index (or both)?
   1. The models are large and use up storage. They can also consume a lot of
      resources (including batteries)
   2. Given the design of kmdb the user may opt out on one device (mobile) but
      opt in on another (desktop). We need to consider how we'd handle this but,
      potentially, we could just not sync the data to devices that have disabled
      the feature.
5. Whilst LiteRT allows for swapping models, indexes built with embeddings from
   one model can't be used by another model. Swapping models will require a
   recalculation of the vectors so how to we ensure that we track the model in
   use?
6. Is the vector indexing even possible in a web environment?

We may need to consider a future proposal for a server version of kmdb that
could host the synchronised files as well as generate indexes. This would help
support the web implementation (offloading the work to the server) but
creates/boosts the need for security and data encryption. It is critical though
that we remain local first and the web version would still work, it would just
have limited features.

## 7. Implementation Roadmap

The implementation must not rely on Flutter - it must be a portable Dart
implementation.

TBD
