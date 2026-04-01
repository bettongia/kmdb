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

Calls to the CLI's `put` command should use a mixture of flush/no-flush usage.
Don't use the CLI's scripting and pipeline capability.

At various points in the test run you should `get` a number of records at
various times - testing records that you know exist and know are not in the
database.

You should also delete records at various times and check that they cannot be
recalled.

Essentially, use the CLI like a person would, creating, getting & deleting
records as well querying the database. You would use different output modes and
should check the output matches what you expect.

This testing could potentially run for a long time so consider putting this
testing in its own directory and file. Also consider an approach to ensuring
that this test is only run when explicitly called.

To be clear, the test needs to be codified (built) in Dart using the standard
testing approach.

## Open questions

{A checklist of open questions, mark each one off as they are answered}

## Investigation

{Investigation notes}

## Implementation plan

{Checklists and notes for the implementation work}

## Summary

{Dot points highlighting the work undertaken}
