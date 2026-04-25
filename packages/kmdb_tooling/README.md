# kmdb_tooling

Internal helpers for KMDB code-generation tooling.

This package is **not published to pub.dev** and is intended only for use as
a `dev_dependency` from other packages in the KMDB workspace. It provides
shared `dev_loader` helpers that are imported by code-generation pipelines
(for example, the bundled stopword/wordlist loaders used by `kmdb_lexical`).

There is no public stable API surface — types may change without notice.

## License

Apache-2.0.
