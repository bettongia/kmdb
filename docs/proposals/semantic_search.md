# Semantic text search

Semantic search handles "intent" and "themes," allowing a search for "memory
leak" to find documents discussing "garbage collection issues" even if the words
don't match.

The approach used in kmdb will be to use a small embedding model to generate
vectors.

## Example

A [spike solution (bge_embeddings)](../../spikes/bge_embeddings/) has been
prepared in order to validate the viability of the approach and configure the
FFI bindings against the ONNX runtime.

Running the following command provides the normalized 384-dim vector (as a JSON
array) constructed from the input text:

```sh
cat sample.txt | dart bin/embed.dart >sample.out
```

The first entries in `sample.out` appear as follows:

```json
[-0.07721628383415412,0.03673409050198489,0.03330454097121675,0.02108989652240076,-0.031751226672150155,-0.002696639549431111,-0.04909326037047926,-0.012217435974202587,0.021918372141368304,-0.04907746934157675,-0.051221672782060725,-0.07480958737533583,0.006425653074367868,0.04452357794339675,0.09581140635971289,0.019036522849333732,-0.00844384495910596,0.10933875708540869,-0.017508018680764223,-0.049802242625170634,0.09278090358391061,-0.10388749391167917,0.0490493211316716,-0.01149763019952789,0.011815127116102553,0.028726760708876573,-0.018008032568614954,...]
```

With an input size of 1.5Kb (sample.txt), the resulting output is about 9Kb.

Running the following will output the token count and token list:

```sh
cat sample.txt | dart bin/tokens.dart
```

Output:

```sh
Count : 290
Tokens: ["[CLS]","b","##ge","landmark","em","##bed","##ding","a","chunk","##ing","##-","##free","em","##bed","##ding","method","for","retrieval","augmented","long","##-","##con","##text","large","language","models","https","ar","##xi","##v","org","abs","240","##2","115","##7","##3","large","language","models","ll","##ms","call","for","extension","of","context","to","handle","many","critical","applications","however","the","existing","approaches","are","prone","to","expensive","costs","and","inferior","quality","of","context","extension","in","this","work","we","propose","##ex","##tens","##ible","em","##bed","##ding","which","realizes","high","##-","##qual","##ity","extension","of","ll","##m","##'","##s","context","with","strong","flexibility","and","cost","##-","##ef","##fect","##ive","##ness","ex","##tens","##ible","em","##bed","##ding","stand","as","an","enhancement","of","typical","token","em","##bed","##ding","which","represents","the","information","for","an","ex","##tens","##ible","scope","of","context","instead","of","a","single","token","by","lever","##aging","such","compact","input","units","of","higher","information","density","the","ll","##m","can","access","to","a","vast","scope","of","context","even","with","a","small","context","window","ex","##tens","##ible","em","##bed","##ding","is","systematically","opt","##imi","##zed","in","architecture","and","training","method","which","leads","to","multiple","advantages","1","high","flexibility","of","context","extension","which","flex","##ibly","supports","ad","##-","##ho","##c","extension","of","diverse","context","lengths","2","strong","sample","efficiency","of","training","which","enables","the","em","##bed","##ding","model","to","be","learned","in","a","cost","##-","##ef","##fect","##ive","way","3","superior","compatibility","with","the","existing","ll","##ms","where","the","ex","##tens","##ible","em","##bed","##ding","can","be","seam","##lessly","introduced","as","a","plug","##-","##in","component","comprehensive","evaluation","##s","on","long","##-","##con","##text","language","modeling","and","understanding","tasks","verify","ex","##tens","##ible","em","##bed","##ding","as","an","effective","efficient","flexible","and","compatible","method","to","extend","the","ll","##m","##'","##s","context","[SEP]"]
```

## Design

### Embedding Model Selection

The [BGE Small En v1.5](https://huggingface.co/BAAI/bge-small-en-v1.5) model
will be used in this work. The rationale for this is based on a reasonable token
limit that should be able to handle article-length tests of around 10 pages. The
model features:

- ~130MB, 384 dimensions, handles up to 512 tokens
- Consistently outperforms MiniLM-L6 on retrieval benchmarks despite similar
  size
- Specifically strong on passage retrieval, which maps well to academic search

### Tokenisation

The same tokenisation process will be used in this work and the
[Lexical Search](lexical_search.md) part of this proposal. The
[icu_tokenizer](../..spikes/icu_tokenizer) spike solution has proven out the
tokeniser approach.

### Chunking

Chunking by ~512 tokens with overlap will be utilised in this body of work. The
spike solution implements a very basic chunking solution

Future work may look to chunk by sentence, paragraph or section (intro, methods,
results, etc.).

### Embeddings & Similarity Metric

Text is converted into floating-point arrays (embeddings) using the selected
model. The similarity between the query vector ($A$) and a document vector ($B$)
is measured using cosine similarity:

$$\text{similarity} = \cos(\theta) = \frac{\sum_{i=1}^{n} A_i B_i}{\sqrt{\sum_{i=1}^{n} A_i^2} \sqrt{\sum_{i=1}^{n} B_i^2}}$$

This is implemented in the
[`cosineSimilarity`](../../spikes/bge_embeddings/lib/src/math_utils.dart)
function.

### Index Strategy

As kmdb is designed to operate across mobile, web and desktop platforms, and
that the database is not expected to be large, it is likely that the "Flat
Index + SQ8" approach will provide the best approach.

At <50k items, brute-force scanning quantized vectors is faster and likely more
battery-efficient than building complex graphs.

### Open design questions

Many questions that arise in this design are also applicable to the
[Lexical Search](lexical_search.md) sub-proposal and are answered in that
document.

#### Q: How are inserts, updates and deletes handled?

Each document write must update the index. Modifications that include the
indexed field as well as the deletion of documents present the need to update
the index.

##### A:?

Can the Base index + overlay pattern used in the Lexical Search proposal also
work here?
