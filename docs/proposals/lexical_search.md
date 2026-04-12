# Lexical search

This document is a sub-proposal for lexical indexing of kmdb document values and
is annexed under the broader
[Technical Proposal: Text Indexing and Search](text_search.md) proposal.

Rudimentary filtering of text-based values via operators such as `eq`, `ne`,
`contains`, `startsWith` and `endsWith` lack the capabilities provided by
lexical (keyword) and semantic search. Lexical indexing and search has a long
history of development and implementations such as
[Apache Lucene](https://lucene.apache.org/) and
[Tantivy](https://github.com/quickwit-oss/tantivy). Adding the ability for a
user to create a lexical search index will provide kmdb with a more useful
search approach for textual values.

Lexical search handles exact matches and specific technical identifiers (e.g.,
elf, space, mTLS).

Prior to reading this document please review
[Technical Proposal: Text Indexing and Search](text_search.md) as it describes
the broader program of work and key scoping items and requirements.

## Example

Consider the following example input regarding a book that is being `insert`ed
into kmdb:

```json
{
  "title": "The strange case of Dr. Jekyll and Mr. Hyde",
  "author": "Stevenson, Robert Louis",
  "subjects": ["Science fiction", "Horror", "Fiction"],
  "description": "\"The Strange Case of Dr. Jekyll and Mr. Hyde\" by Robert Louis Stevenson is a Gothic horror novella published in 1886. When London lawyer Gabriel John Utterson investigates strange occurrences involving his old friend Dr. Henry Jekyll and a murderous criminal named Edward Hyde, he uncovers a disturbing mystery. This defining work of Gothic horror explores the duality of human nature and has profoundly influenced popular culture, making \"Jekyll and Hyde\" synonymous with hidden evil beneath respectable appearances.",
  "link": "https://www.gutenberg.org/ebooks/43"
}
```

Both the `title` and `description` fields are likely candidates for a lexical
search index as users will often want to search a collection of such documents
for books with the same keyword(s).

Note: Whilst the `subjects` field is textual it (likely) draws from a taxonomy
that the user could use in a basic filter rather than needing a lexical search.

In order to build an index entry for the `description` field, the process
described in the subsections below would generally occur.

### 1. Tokenization (Segmentation)

The engine breaks the string into individual "tokens." Using
[Unicode Text Segmentation](https://www.unicode.org/reports/tr29/) rules (for
example), it handles punctuation and boundaries.

- **Input:** `"The Strange Case of Dr. Jekyll..."`
- **Output:**
  `[The], [Strange], [Case], [of], [Dr], [Jekyll], [and], [Mr], [Hyde], [by], [Robert], [Louis], [Stevenson] ...`

It is important to recognise that not all languages are tokenised in the same
way. If that text were in Chinese, tokenisation may be the hardest part of the
overall process. Instead of looking for spaces, the engine would use a segmenter
(like **Cang-jie** in Tantivy or **Jieba** in SQLite) to determine that
`伦敦律师` is `[London], [Lawyer]` rather than four individual characters.

### 2. Normalization & Filtering

Next, we clean the tokens to ensure that a search for "jekyll" matches "Jekyll."

- **Lowercase:** All tokens become lowercase.
- **Output:**
  `[the], [strange], [case], [of], [dr], [jekyll], [and], [mr], [hyde], [by], [robert], [louis], [stevenson], [is], [a], [gothic], [horror] ...`

Importantly, case folding depends on the language in use. The
[Unicode Case Folding Properties](https://www.unicode.org/Public/12.1.0/ucd/CaseFolding.txt)
provides a mapping of characters to their other case.

The [icu_tokenizer](../..spikes/icu_tokenizer) spike solution has proven out the
tokeniser approach.

### 3. Remove stop words (maybe)

Traditionally, a set of words were removed due to their frequency and perceived
low-value in search use cases - think words like `the`, `and` and `is`. However,
with increased storage being available on most devices, there is a trend away
from removing stop words and keeping them to improve the precision in the search
index. Algorithms such as BM25 (more fully discussed later) are able to
determine weightings for certain words in a corpus based on their frequency -
for example:

- "Jekyll" may appear on a small number of times across the corpus so it gets a
  higher weighting
- "the" appears a lot more across the corpus so it gets a very low weighting

For the implementation work proposed here we will index all words — this step is
a no-op by default and the full output from step 2 passes through unchanged.
Future work may allow the user to opt in to stop-word removal using a
pre-defined set that can be enhanced or reduced with custom stop words.

### 4. Stemming

We reduce words to their base form so that a search for "investigating" finds
"investigates."

- `investigates` $\rightarrow$ `investig`
- `investigating` $\rightarrow$ `investig`
- `occurrences` $\rightarrow$ `occurr`
- `disturbing` $\rightarrow$ `disturb`

### 5. Creating the Inverted Index

Now we map these processed terms to the Document IDs in which they appear. Let's
assume the text above is **Doc #1**.

| Term       | Doc IDs |
| :--------- | :------ |
| **case**   | 1       |
| **dual**   | 1       |
| **gothic** | 1       |
| **hyde**   | 1       |
| **jekyll** | 1       |

Phrase search (matching words in adjacent positions) is out of scope — the index
stores only term → document membership, not term position within the document.

### 6. Storage & Compression

kmdb makes use of append-only approaches to storing documents, using the
benefits of that approach for the purpose of synchronising across multiple
devices. However, indexes are defined at the device level and are not
synchronised. The design/implementation of the lexical search approach needs to
determine an architecture that:

1. Makes effective use of memory and storage
1. Allows for the index to be stored on-disk such that it is persisted across
   sessions. If no documents are inserted, updated, or deleted the index does
   not need to change.

Ideally, the approach will allow for the index to be added to (due to inserts)
or modified (due to updates or deletes) without requiring the index to be
rebuilt on each event. Whilst this proposal is only scoped for document fields
(where the value is likely to be relatively small in size), an ideal approach
could also handle larger texts that are stored in the [vault](vault.md).
However, this is not critical and an alternative approach to those larger texts
can be sought.

At kmdb's expected scale (tens of thousands of documents, a vocabulary of
roughly 50–100k unique stems), a sorted `Map<String, List<String>>` (term → list
of doc IDs) held in memory is sufficient. Lookup is O(log n) with a sorted
structure and the memory footprint is manageable. This is also straightforward
to update incrementally on each document write.

The following techniques are used by production FTS engines at much larger
scale. They are noted here for context but are **not** committed design choices
for this implementation. They represent potential upgrade paths if data volumes
ever demand it:

1.  **Finite State Transducer (FST):** A very compact on-disk dictionary
    structure with O(m) lookup (m = word length), using ~2–4 bytes per term.
    However, an FST is essentially read-only once built — inserting a new term
    requires rebuilding the entire structure, which conflicts with incremental
    update requirements. No Dart FST library exists; it would need to be written
    from scratch.
2.  **Delta Encoding:** Rather than storing doc IDs as `[1, 5, 12]`, store the
    gaps between them (`[1, 4, 7]`). Saves space in large postings lists.
3.  **Bit-Packing (SIMD-BP128):** Packs multiple IDs into a single CPU register
    using SIMD instructions, enabling very fast decompression of postings lists
    at scale.

### 7. How a Search Happens

When you search for **"Jekyll mystery"**:

1.  The search engine processes your query exactly like the text:
    `[jekyll], [mysteri]`.
2.  It looks up both terms in the **Dictionary**.
3.  It retrieves the **Postings Lists** for both.
4.  It performs an **Intersect (AND)** operation on the lists to find documents
    where both appear.
5.  It calculates a **BM25 Score** (relevance) based on how many times "Jekyll"
    appears in this 400-word snippet versus the rest of your database.

## Design

### Text Preprocessing Pipeline

#### Tokenisation

[Unicode Text Segmentation](https://www.unicode.org/reports/tr29/) will be
utilised. Key resources:

- [ICU Documentation](https://unicode-org.github.io/icu/)
- The [C/C++ implementation](https://github.com/unicode-org/icu/tree/main/icu4c)
  handles a broad range of Unicode concerns but these items are specific to
  tokenising/segmentation:
  - The
    [C Header file](https://github.com/unicode-org/icu/blob/main/icu4c/source/common/unicode/ubrk.h)
    wraps the C++ implementation. The `ubrk_open()`, `ubrk_next()`, and
    `ubrk_previous()` functions are used for all C-based segmentation tasks.
  - [Segmenting Rules data](https://github.com/unicode-org/icu/tree/main/icu4c/source/data/brkitr)

##### Implementation approach

The preferred approach is a `dart:ffi` binding to the ICU C library using the
`UBRK_WORD` break iterator. ICU is a system library on all of kmdb's target
platforms, so no bundling is required:

| Platform    | ICU availability                       |
| :---------- | :------------------------------------- |
| macOS / iOS | `libicucore.dylib` — ships with the OS |
| Android     | Available via the NDK                  |
| Linux       | `libicu` — standard, widely packaged   |
| Windows     | Bundled with Windows 10+               |

This makes the FFI surface narrow and the deployment story clean — the binding
calls three functions (`ubrk_open()`, `ubrk_next()`, `ubrk_previous()`) against
a library that is already present on the target device. ICU's word rules also
include built-in handling for numeric literals and mixed-case identifiers, which
directly covers the technical identifier cases (`0x8004210B`, `mTLS`) that a
custom tokeniser would need explicit rules for.

The investigation should confirm:

1. Whether `dart:ffi` can link against the system ICU on each platform without
   additional build configuration.
2. Whether the `UBRK_WORD` iterator handles the technical identifier cases in
   the way the proposal requires.

##### Fallback

If the ICU FFI path proves impractical on any target platform, the fallback is a
custom `RegExp`-based tokeniser written in pure Dart. This would handle the
common English prose cases well but would require explicit rules for technical
identifiers and would not provide full UAX #29 compliance. Either way, the
tokeniser is implemented behind a `Tokeniser` interface so that the
implementation can be swapped without changes to the indexing pipeline — this
also satisfies the pluggability requirement for future multi-language support
(see [top-level proposal](text_search.md) §3.1).

#### Stop-word filtering

Preference will be to index all words by default. A pre-defined set of
stop-words will be made available for support languages (`en` at this stage) and
utilise [Stopwords ISO](https://github.com/stopwords-iso) - specifically the
[en listing](https://github.com/stopwords-iso/stopwords-en/blob/master/stopwords-en.txt).
This listing will be defined within a Dart code file (rather than loaded from a
resource). A future feature may allow for this list to be overridden or altered.

#### Stemming

[Snowball](https://snowballstem.org/) will be used for stemming. The
[snowball_stemmer](https://pub.dev/packages/snowball_stemmer) Dart package
provides the required functionality.

Lemmatisation will not be utilised.

Note: As previously mentioned, multi-language support is not in-scope for this
work. However, snowball has been adapted to many languages, allowing for future
work to utilise this approach

#### Index Structure

The index uses four key types in the KV store, all in `$fts:` system namespaces
exempt from the session object cache and materialised view cache:

```
$fts:{ns}:{field}:{term}:{docId}   →  tf (int)               base index
$fts:overlay:{ns}:{field}:{docId}  →  Map<String,int>|TOMBSTONE  overlay
$fts:corpus:{ns}:{field}           →  { n, totalTokens }     corpus stats
$fts:doc:{ns}:{field}:{docId}      →  tokenCount (int)       per-doc forward index
```

**Base index** stores the term frequency (tf) — the number of times the term
appears in the indexed field of that document — as the entry value. Storing tf
here rather than an empty sentinel is required for BM25 scoring (see Ranking
Algorithm). One entry exists per term/document pair.

**Overlay** stores the current valid `term → tf` map for recently-modified
documents, or a tombstone marker for deletions. It serves as the authoritative
source for any document that has been written since the last compaction,
allowing query-time filtering without a read-before-write on the write path.

**Corpus stats** maintains the two values needed to compute `avgdl` at query
time: the total number of indexed documents (`n`) and the sum of all document
token counts (`totalTokens`). `avgdl = totalTokens / n`.

**Per-doc forward index** stores the token count of the most recently indexed
value for each document. This is the sole case where a targeted read precedes a
write — on update and delete, this key is read to obtain the old token count so
that `totalTokens` in the corpus stats can be adjusted correctly.

##### Write behaviour

All writes (except the one targeted read described below) are included in a
single `WriteBatch` with the document write, making them atomic. The WAL
provides crash recovery with no additional work required.

- **Insert:** tokenise the new field value. Add one base index key per term
  (value = tf). Write the per-doc token count. Increment `n` and add the new
  token count to `totalTokens` in the corpus stats. No overlay entry is needed —
  there is no prior state to invalidate.

- **Update:** read `$fts:doc:{ns}:{field}:{docId}` to obtain the old token count
  (one targeted read, outside the batch). Tokenise the new field value. Add new
  base index keys (additive — stale keys from the old value are left in place).
  Write the new overlay entry (`term → tf` map). Update the per-doc token count.
  Adjust `totalTokens` by `newCount − oldCount` in the corpus stats. `n` is
  unchanged.

- **Delete:** read `$fts:doc:{ns}:{field}:{docId}` to obtain the old token count
  (one targeted read, outside the batch). Write a tombstone to the overlay.
  Delete the per-doc token count entry. Decrement `n` and subtract the old token
  count from `totalTokens` in the corpus stats. Stale base index keys are left
  in place and cleaned up at compaction.

##### Query behaviour

For each query term, scan the base index prefix `$fts:{ns}:{field}:{term}:` to
collect `(docId, tf)` pairs, then filter through the overlay:

- No overlay entry for a docId → trust the base index tf, include the result.
- Overlay entry present → include only if the term appears in the overlay map;
  use the overlay tf for scoring (it supersedes the base index value).
- Tombstone present → exclude unconditionally.

After filtering, `df` for each term is the count of surviving results — derived
naturally from the scan rather than stored separately. Read `$fts:corpus:` once
per query to obtain `n` and `totalTokens`, then compute
`avgdl = totalTokens / n`. Score each document using BM25 (see Ranking
Algorithm).

The in-memory map built from the filtered scan is transient and not kept live
between queries.

##### Compaction

Each document in the overlay is processed as a single `WriteBatch`:

For a **live overlay entry** (term → tf map):

```
WriteBatch:
  DELETE $fts:{ns}:{field}:{stale_term_1}:{docId}   ← terms absent from overlay
  DELETE $fts:{ns}:{field}:{stale_term_2}:{docId}
  PUT    $fts:{ns}:{field}:{current_term}:{docId}   ← update tf if changed
  ...
  DELETE $fts:overlay:{ns}:{field}:{docId}
```

For a **tombstone entry**:

```
WriteBatch:
  DELETE $fts:{ns}:{field}:{term_1}:{docId}         ← all terms for this doc
  DELETE $fts:{ns}:{field}:{term_2}:{docId}
  ...
  DELETE $fts:doc:{ns}:{field}:{docId}
  DELETE $fts:overlay:{ns}:{field}:{docId}
```

The ordering is critical for crash safety. Because all removals and the overlay
clearance are in the same `WriteBatch`, a crash mid-compaction can only leave a
docId in one of two states:

- **Overlay still present** — queries continue to filter correctly. The next
  compaction cycle will process the entry again.
- **Overlay and stale entries both gone** — index is fully clean for this docId.

The unsafe state — overlay cleared but stale entries remaining — cannot occur.
If compaction is interrupted across multiple documents, each already-processed
docId is consistent and unprocessed docIds remain in the overlay unchanged.

##### Cache exemption

All `$fts:` namespaces (`$fts:`, `$fts:overlay:`, `$fts:corpus:`, `$fts:doc:`)
are exempt from the session object cache and materialised view cache. FTS index
data does not pass through these caches and therefore does not trigger
generation counter churn on document writes.

#### Ranking Algorithm: BM25

BM25 (Best Matching 25) calculates relevance by looking at term frequency (tf)
and inverse document frequency (idf), while adjusting for document length.

$$\text{BM25}(D, Q) = \sum_{i=1}^{n} \text{IDF}(q_i) \cdot \frac{f(q_i, D) \cdot (k_1 + 1)}{f(q_i, D) + k_1 \cdot (1 - b + b \cdot \frac{|D|}{\text{avgdl}})}$$

- $IDF(q_i)$: Logarithmic scale of how rare the term is across the dataset.
- $f(q_i, D)$: Number of times term i appears in document D.
- $|D| / avgdl$: Normalization factor to prevent long documents from ranking
  higher simply by containing more words.
- $k_1$ (default 1.2) and $b$ (default 0.75) are tuning constants. These will be
  configurable per-collection.

### Open design questions

#### Q: Can the lexical index be built lazily, on first query?

Index generation for lexical search is likely to be non-trivial for
moderately-sized databases and involves more "work" that a scan + filter. Lazily
building the index will mean that the first search will likely cause very high
latency on returning results to the user and will have a negative UX.

##### A: This should be configurable

When the index is created a flag (`--lazy`) will indicate that the index
creation will be deferred until first use. By default, the index will be built
when the index has been configured/created. This differs from the current
approach but the indexing process is likely to be more substantial for full text
than the indexing of basic values. The API developed for this proposal may need
to sit one layer above the current indexing layer, allowing for the index to be
created and then built. Alternatively, the lexical search presents the need for
a completely different indexing approach and API.

#### Q: How are inserts, updates and deletes handled?

Each document write must update the inverted index. Modifications that include
the indexed field as well as the deletion of documents present the need to
update the index.

How is this done atomically with the document write (following the secondary
index `WriteBatch` pattern)? Deferring it asynchronously risks index/data
divergence on crash.

##### A: Base index + overlay pattern

Inserts add term keys to the base index in the same `WriteBatch` as the document
write. Updates and deletes write to an overlay rather than modifying the base
index directly, avoiding a read-before-write. Stale base index entries are
cleaned up at compaction time using a per-document atomic `WriteBatch`.

See the Index Structure section for the full design, including crash safety
guarantees.

#### Q: Which fields are indexed?

Is the entire document serialized to text for indexing, or can the developer
nominate specific fields (e.g. `title`, `body`)?

The latter is consistent with how secondary indexes are defined at
`KmdbDatabase.open()` time and would be more efficient.

##### A: The user creates an index for a specific field

The user will create an index much the same as they do in the current system.
The index is created for a specified field in a collection.

#### Q: `$fts` namespace design:

If FTS (full text search) index data is stored in system namespaces (analogous
to `$index`), the namespace generation counter invalidation in the Cache Layer
will fire on every FTS write, potentially causing excessive cache churn. Is
there a mitigation?

##### A: Exempt `$fts:` namespaces from the cache layer

The `$fts:` and `$fts:overlay:` system namespaces are excluded from the session
object cache and materialised view cache. These caches serve application
documents; FTS index data does not pass through them and therefore does not
trigger generation counter invalidation on document writes.

#### Q: Will lexical searching support a query DSL?

Projects such as
[Lucene](https://lucene.apache.org/core/2_9_4/queryparsersyntax.html) support a
query syntax that allows for techniques such as boolean searches, groupings etc.

##### A: No

Not at this time.

## API design

### CLI

FTS index management and querying are both surfaced under a new top-level
`search` command. Management subcommands are distinguished from a query by
whether the first argument is a known subcommand name; if it is not, the
invocation is treated as a search query.

#### Index management

```
kmdb <db> search list <collection>
kmdb <db> search create <collection> <field> [--lazy]
kmdb <db> search info <collection> <field>
kmdb <db> search delete <collection> <field>
kmdb <db> search build <collection> <field> [--force]
```

- **`list`** — lists all FTS indexes configured for the collection, with their
  current status and last-built timestamp.
- **`create`** — registers and builds an FTS index on `<field>`. By default the
  index is built immediately; `--lazy` defers the build until first search.
- **`info`** — prints detailed state for a single index (status, build
  timestamp, term count, document count).
- **`delete`** — removes all stored index entries and deregisters the index.
- **`build`** — explicitly triggers an index build. `--force` rebuilds even if
  the index is current.

#### Search query

```
kmdb <db> search <collection> "<query terms>"
          [--fields <field1,field2,...>]
          [--filter <json>]
          [--select <field1,field2,...>]
          [--limit <n>] [--offset <n>]
          [--verbose]
          [--output table|json]
```

- **`--fields`** — restrict the search to the specified FTS-indexed fields.
  Omitting this flag searches all FTS-indexed fields in the collection. Fields
  listed here that have no FTS index are silently skipped and reported in result
  metadata.
- **`--filter`** — a document predicate in the existing filter DSL (same syntax
  as `scan --filter`). Applied as a pre-filter to reduce the candidate set
  before FTS scoring. Does not affect relevance ranking.
- **`--select`** — projects specific document fields in the output, mirroring
  `scan --select`.
- **`--verbose`** — in tabular output, adds a column per searched field showing
  its individual BM25 score. Has no additional effect on JSON output, which
  always includes per-field scores.

##### Multi-field scoring

When multiple fields are searched, each document receives a BM25 score per field
in which it matches. The document's rank is determined by its **highest**
per-field score. Per-field scores are always available in JSON output and in
tabular output when `--verbose` is specified.

##### Handling missing indexes

- If a field listed in `--fields` has no FTS index it is skipped silently. The
  `skipped` list in result metadata identifies which fields were omitted.
- If no searchable fields remain (none of the requested fields, or no fields in
  the collection, have an FTS index) the command returns zero results and
  includes an explanatory note in the metadata. This is not treated as an error.

##### Output — tabular (default)

A metadata header is printed before the result rows:

```
searched: description, title
skipped (no fts index): summary
2 results

rank  score  title                                        author
1     0.842  The Strange Case of Dr. Jekyll and Mr. Hyde  Stevenson, Robert Louis
2     0.631  Frankenstein                                 Shelley, Mary
```

With `--verbose`:

```
rank  score  description  title  title                                        author
1     0.842  0.842        0.310  The Strange Case of Dr. Jekyll and Mr. Hyde  Stevenson, Robert Louis
2     0.631  0.631        -      Frankenstein                                 Shelley, Mary
```

No results due to missing indexes:

```
searched: (none)
skipped (no fts index): description, title
0 results — no FTS indexes found for the requested fields.
```

##### Output — JSON (`--output json`)

Full fidelity; per-field scores are always included regardless of `--verbose`.

```json
{
  "metadata": {
    "query": "Hyde Gothic",
    "searched": ["description", "title"],
    "skipped": ["summary"],
    "total": 2
  },
  "results": [
    {
      "rank": 1,
      "score": 0.842,
      "fieldScores": { "description": 0.842, "title": 0.31 },
      "document": {
        "_id": "01234567-...",
        "title": "The Strange Case of Dr. Jekyll and Mr. Hyde",
        "author": "Stevenson, Robert Louis"
      }
    },
    {
      "rank": 2,
      "score": 0.631,
      "fieldScores": { "description": 0.631 },
      "document": {
        "_id": "89abcdef-...",
        "title": "Frankenstein",
        "author": "Shelley, Mary"
      }
    }
  ]
}
```

`fieldScores` includes only fields where the document scored — fields in which
the document had no matching terms are omitted from the map.

---

### Dart library API

The CLI is a thin layer over the Dart library API. The library exposes FTS index
management via `FtsManager` (analogous to `IndexManager` for secondary indexes)
and search via a `search()` method on `KmdbCollection<T>`.

#### Index definition

FTS indexes can be declared at `KmdbDatabase.open()` time alongside secondary
indexes, or registered dynamically via `FtsManager`. Both paths go through the
same `FtsManager` internally — `FtsIndexDefinition` at `open()` is a convenience
that calls `FtsManager.createIndex()` for any definition not already present in
the KV store. The KV store (`$fts:corpus:` and `$fts:doc:` namespaces) is the
single source of truth for index state; the `open()` declarations and
`local/config.json` (CLI) are registration mechanisms that drive the same
underlying call.

```dart
// Declared at open time (library users)
final db = await KmdbDatabase.open(
  store,
  collections: {
    'books': KmdbCollection<Book>(codec: BookCodec()),
  },
  ftsIndexes: [
    FtsIndexDefinition(collection: 'books', field: 'description'),
    FtsIndexDefinition(collection: 'books', field: 'title'),
  ],
);

// Dynamic management (used by the CLI via local/config.json)
await db.ftsManager.createIndex('books', 'description', lazy: false);
await db.ftsManager.buildIndex('books', 'description', force: false);
final state = await db.ftsManager.getState('books', 'description');
await db.ftsManager.deleteIndex('books', 'description');
```

#### Search

`search()` returns a `Future<FtsSearchResult<T>>`. A streaming variant is not
provided in this implementation — at kmdb's expected scale, full result sets fit
comfortably in memory and `limit`/`offset` mitigate any concern about large
pages. Reactive search (re-executing on writes, analogous to `watch()`) is noted
as a future possibility but is out of scope here.

```dart
final results = await db.collection<Book>('books').search(
  'Hyde Gothic',
  fields: ['description', 'title'], // optional; omit to search all FTS fields
  filter: Filter.eq('type', 'book'), // optional pre-filter
  limit: 10,
  offset: 0,
);
```

#### Result types

```dart
/// The result of an FTS search, including metadata and ranked hits.
class FtsSearchResult<T> {
  final FtsSearchMetadata metadata;
  final List<FtsSearchHit<T>> hits;
}

/// Metadata describing how the search was executed.
class FtsSearchMetadata {
  /// The original query string.
  final String query;

  /// Fields that were successfully searched.
  final List<String> searched;

  /// Fields requested (via [FtsSearchOptions.fields]) that had no FTS index
  /// and were therefore skipped.
  final List<String> skipped;

  /// Total number of matching documents before [FtsSearchOptions.limit] and
  /// [FtsSearchOptions.offset] are applied.
  final int total;
}

/// A single ranked result.
class FtsSearchHit<T> {
  /// 1-based rank position.
  final int rank;

  /// The highest per-field BM25 score for this document.
  final double score;

  /// BM25 score for each field in which this document matched.
  /// Fields where the document did not score are absent from the map.
  final Map<String, double> fieldScores;

  /// The document key.
  final String id;

  /// The decoded document.
  final T document;
}
```
