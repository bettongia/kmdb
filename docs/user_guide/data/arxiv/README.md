# ArXiv Database articles from 2025

The [arxiv-db-2025.ndjson](arxiv-db-2025.ndjson) file is based on the arXiv
dataset
[available from kaggle](https://www.kaggle.com/datasets/Cornell-University/arxiv).

The data is made available under a
[CC0: Public Domain](https://creativecommons.org/publicdomain/zero/1.0/) license

It's a large dataset so an extraction of the 2025 articles was performed as
follows:

```sh
jq -c 'select((.id | startswith("25")) and (.license == "http://arxiv.org/licenses/nonexclusive-distrib/1.0/") and (.categories | contains("cs.DB")))' arxiv-metadata-oai-snapshot.json >arxiv-db-2025.ndjson
```
