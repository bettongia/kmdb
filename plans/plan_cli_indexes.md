# Add index commands and collection commands to the CLI

**Status**: Open

**PR link**: {A link to the PR submitted for this plan}

## Problem statement

Most of the kmdb functionality is available via the CLI but the ability to
create and delete [secondary indexes](../docs/spec/16_secondary_indexes.md) is
missing. This plan looks to add the ability to create, delete and get info on
indexes in a given collection.

Indexes are created within collections and are used to improve search
(filtering) latency. As no schema is enforced in a collection, indexes may not
align to all documents in a collection as it's reasonable to assume that a user
search for a specific value doesn't want to search for things without a value.
However, a search for documents that have a no/null value is basically a search
for documents not in the index. See also "Missing vs Null Semantics" in the
Filter DSL specification.

There is currently two collection-specific commands and consideration needs to
be made as to if the CLI ergonomics can be improved as part of this work:

- `create-collection`: To create an empty collection
- `collections`

The scope of this plan is focussed on indexing fields to support the filter DSL
for querying. The [Hybrid Text Search Engine](../docs/proposals/text_search.md)
looks at full-text search facilities for improved search within a field - any
design should be mindful of this roadmap item but maintain the scope described
here.

A smaller aspect to this plan is to provide the ability to delete a collection
via the CLI. This deletion would also delete all documents in the collection.
The work is presented in this plan as it can be bundled with the index-based
work as it also operates at the collection level.

## Open questions

### How are indexes synchronised?

The actual index is constructed locally when first used but:

1. Is the index definition synchronised to remotes?
1. Is the index content synchronized to remotes or only even built locally?
1. Are these points clearly outlined in the spec?

### What's the best command line structure?

Can the CLI be simplified in terms of the collection-centric commands? For
example (consider if singular/plural usage is better):

1. `collections create <coll>` : to create an empty collection (replacing
   `create-collection`)
2. `collections list` : to list collections in the database (as per the current
   `collections` command)
3. `collections info <coll>` : to get info regarding a collection
4. `collections delete <coll>` : to delete a collection and all documents within
   it.
5. `collections <coll> indexes list` : to list all indexes
6. `collections <coll> indexes create ...` : to create an index
7. `collections <coll> indexes info <index_name>` : to get info regarding an
   index
8. `collections <coll> indexes delete <index_name>` : to delete an index

For the example commands above we need to be aware of any possibility where the
user can create names for collections or indexes that could intersect with
command names. Whilst the above examples present a "telescoping" command format,
having a name-by-name approach (e.g. `<db> <coll> <index> info`) presents a
greater intersection risk. Alternatively, a dot point approach
(`<db>.<coll>.<index>`) may be useful.

SQL uses a `CREATE INDEX <name> ON ...` and there could be an argument that the
kmdb command line support something more like `<db> index create <coll> <name>`
but this feels clunky.

### Should composite indexes be supported?

Is it much more work to allow for indexes to be defined with more than 1 index
entry key?

### Should we maintain index stats?

The approach to indexing (build on first access) can help reduce the impact of
indexing when a write occurs.

We expect the database to be of a small-to-medium size and not very write-heavy.
However, having a lot of indexes on a collection may start to have a negative
effect on searching and general performance. Maintaining index usage stats can
help in advising a user that some indexes can be dropped but, given the
distributed approach to kmdb, this may not be as useful as it is to a
traditional server-based RDBMS.

### Should we support `unique`, `not null` or filtered indexes?

This helps set at least some basic constraints on the database but should be
deferred to later work that looks to adopt schemas. Work on this plan shouldn't
look to implement features that overlay schema-style constraints or advanced
indexing (such as an SQL-based `CREATE INDEX ... WHERE <expr>`). However, the
model for schema configuration should allow for future features.

## Investigation

{Investigation notes}

## Implementation plan

{Checklists and notes for the implementation work}

## Summary

{Dot points highlighting the work undertaken}
