# Semantic text search

Semantic search handles "intent" and "themes," allowing a search for "memory
leak" to find documents discussing "garbage collection issues" even if the words
don't match.

### Phase A — Research Spike

Resolve the blocking unknowns that gate all subsequent phases. No implementation
work should begin on Phases B–E until the questions below are answered.

#### A.1 Embedding Model Selection

Semantic search requires converting document text to floating-point vector
arrays (embeddings) using a local transformer model, hosted via
[LiteRT](https://ai.google.dev/edge/litert). The model choice is not yet
decided.

A model such as Gemma 4 has been suggested, which would allow for "swapping in"
other models at a future date.

> **[Review]:** Gemma is a _generative_ (decoder-only) model, not an embedding
> model. Using it to produce document embeddings is non-standard and would
> require techniques like mean-pooling over the last hidden state, which yields
> lower-quality embeddings than purpose-built bi-encoder models. Since
> generative model use cases (summarisation, agents) are explicitly out of scope
> (§3), there is no longer a reason to prefer Gemma. For local embedding
> generation, consider purpose-built encoder-only models instead:
>
> - [`all-MiniLM-L6-v2`](https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2)
>   (~22MB, 384d, English) — smallest production-quality option
> - [`multilingual-e5-small`](https://huggingface.co/intfloat/multilingual-e5-small)
>   (~120MB, 384d) — if multi-language support is needed
>
> Both can be exported to TFLite/LiteRT format and are a fraction of Gemma's
> size, which matters significantly on mobile where bundle size and memory are
> constrained.

#### A.2 LiteRT FFI Evaluation

Hosting a transformer model requires FFI work to create a Dart library that
interfaces with LiteRT.

> **[Review]:** The FFI requirement is a significant undertaking and likely
> warrants its own plan. Key questions:
>
> 1. LiteRT is a C++ library. The FFI binding will need to be written and
>    maintained for each target platform (Android, iOS, macOS, Windows, Linux).
>    Is there an existing Dart/Flutter package (e.g. `tflite_flutter`) that
>    could provide this, or is a custom binding required? Note that the
>    constraint in §2 (no Flutter) rules out Flutter-dependent packages — a
>    pure-Dart or custom native binding is likely required.
> 2. How is the model file distributed? Bundled with the app (inflating install
>    size), downloaded on first use (requires network, latency), or provided by
>    the platform (reduces portability)? This is a critical UX and
>    infrastructure decision.
> 3. What is the inference latency budget? Embedding a query on-device before
>    each search adds latency. On a low-end mobile device, how long does a
>    single embedding call take with a small model like `all-MiniLM`?

#### C.1 Embeddings & Similarity Metric

Text is converted into floating-point arrays (embeddings) using the model
selected in Phase A. The similarity between the query vector ($A$) and a
document vector ($B$) is measured using cosine similarity:

$$\text{similarity} = \cos(\theta) = \frac{\sum_{i=1}^{n} A_i B_i}{\sqrt{\sum_{i=1}^{n} A_i^2} \sqrt{\sum_{i=1}^{n} B_i^2}}$$

> **[Review]:** If SQ8 quantization (§C.2) is applied, cosine similarity on
> 8-bit integer vectors requires adapted arithmetic. Clarify whether the
> similarity computation happens on the quantized or dequantized vectors, and
> what the accuracy impact is.

#### C.2 Optimizations: Matryoshka & Quantization

There are a few optimisation approaches to consider:

- [Matryoshka Embeddings](https://arxiv.org/abs/2205.13147): Allows truncating
  768d vectors to 128d with \<2% accuracy loss, reducing memory usage by 6x.
- Scalar Quantization (SQ8): Converts 32-bit floats to 8-bit integers. This
  allows for SIMD (Single Instruction, Multiple Data) acceleration on ARM/x86
  CPUs.

See also:
[Vector Quantization Survey and Selection Guide](https://doris.apache.org/docs/dev/ai/vector-search/quantization-survey)

> **[Review]:** Matryoshka requires the _model_ to have been trained with
> Matryoshka Representation Learning (MRL). Not all models support it — confirm
> that the chosen embedding model was trained with MRL before relying on this
> optimization. If starting from 384d (e.g. `all-MiniLM`) rather than 768d, the
> memory saving is smaller but the baseline is already compact.

#### C.3 Cross-Platform Index Strategy

As kmdb is designed to operate across mobile, web and desktop platforms, and
that the database is not expected to be large, it is likely that the "Flat
Index + SQ8" approach will provide the best approach.

Further investigation is needed.

| Platform | Vector Indexing Algorithm | Rationale                                                                                                                 |
| :------- | :------------------------ | :------------------------------------------------------------------------------------------------------------------------ |
| Mobile   | Flat Index + SQ8          | At \<50k items, brute-force scanning quantized vectors is faster and more battery-efficient than building complex graphs. |
| Desktop  | HNSW (Graph-based)        | Fast O(log n) retrieval. Desktop RAM allows for the high memory overhead of the hierarchical graph.                       |
| Web      | IVF-Flat (Clustering)     | Groups vectors into clusters. Only searches the N closest clusters to keep the main thread responsive. _See Phase E._     |

> **[Review]:** The table and the preceding paragraph contradict each other. The
> paragraph states the database "is not expected to be large" and that Flat
> Index + SQ8 "will provide the best approach," yet the table then proposes HNSW
> for desktop and IVF-Flat for web. If the data size assumptions hold (< 50k
> items, as stated for mobile), the same reasoning applies on desktop and web —
> HNSW and IVF-Flat add implementation and maintenance complexity with no
> benefit at this scale.
>
> **Question:** What is the evidence that desktop databases will be
> substantially larger than mobile? If the data is synced across devices, the
> item counts should be comparable. The simpler approach would be to commit to
> Flat Index + SQ8 across all platforms for the initial implementation, with a
> clear upgrade path documented for when item counts warrant it.

#### C.4 Open Questions for Phase C

2. Can the vector index be built lazily, on first query? (Shared with Phase B.)
3. Should the vectors be stored using the [vault](vault.md) rather than in the
   KV/Storage Engine?
4. Can users opt out of vector search specifically? (Shared with Phase A Q4 —
   the opt-out design must be decided before the storage strategy is locked.)
5. As the keyword and vector indexes can be expensive to create, do we need to
   consider an approach where the indexes are synchronised so that other devices
   don't need to generate the index locally?
