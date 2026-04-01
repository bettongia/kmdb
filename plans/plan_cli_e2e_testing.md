# End-to-end testing

**Status**: Open

**PR link**: {A link to the PR submitted for this plan}

## Problem statement

We should configure a test that attempts to replicate a non-trivial user session
using the CLI in batch mode. This will involve multiple calls to the namespace
to build out at least three collections. I would suggest the following
collections and associated document properties:

- `notes`: title (string), body (string), tags (array), creation_date
  (date/string)
- `reading_list`: title (string), authors (array), tags (array), review (string)
- `shopping_list`: item (string), quantity (int), needed (bool)

The test harness should generate at least 1000 synthetic records for each
collection.

Calls to the CLI should use a mixture of flush/no-flush usage. Don't use the
CLI's scripting and pipeline capability.

This testing could potentially run for a long time so consider putting this
testing in its own directory and file. Also consider

## Open questions

{A checklist of open questions, mark each one off as they are answered}

## Investigation

{Investigation notes}

## Implementation plan

{Checklists and notes for the implementation work}

## Summary

{Dot points highlighting the work undertaken}
