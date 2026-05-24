# Roadmap

This directory is used to track roadmap items. A roadmap is prepared for a
specific release version.

Individual, non-trivial roadmap items are described using a plan (see
`../plans`).

An example roadmap file is provided below. This example is for `v0.01` of an
application so would be stored as `0_01.md`. Items of note in the example:

- When a roadmap item has been completed, its title is tagged with `✅ Complete`
  - (not shown) When all roadmap items have been completed, the roadmap is
    marked complete (`# v0.01 ✅ Complete`)
- If a plan is used to undertake a roadmap item, it should be linked against the
  roadmap item (as seen in the "Collections Schema" section).
- _The YAML header is a Pandoc markdown feature._

```md
---
title: 0.01 Roadmap
subtitle: Will it work?
toc-title: "Contents"
...

# v0.01

## CLI tidy up ✅ Complete

- Remove the `put` command

## Collection Schemas ✅ Complete

> Implemented in
> [`../plans/completed/plan_cli_schemas.md`](../plans/completed/plan_cli_schemas.md).

## Range-predicate index scans

Secondary indexes currently accelerate **equality predicates** only
(`Field('x').equals(v)`). Range filters (`isGreaterThan`, `isLessThan`,
`isBetween`, `startsWith`) are always evaluated in-memory after a full namespace
scan.
```

When the version roadmap has been completely implemented, make sure the status
is updated to "✅ Complete" and move the plan into the `completed` directory.
