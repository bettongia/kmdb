# Logging Callback

**Status**: Open

**PR link**: {A link to the PR submitted for this plan}

## Problem statement

`kmdb` should emit logs in a resource-sensitive manner. Instead of using logging
frameworks, `kmdb` should notify callback functions that an application can
configure.

Each layer should identify itself in logs so as to help developers determine
where inside `kmdb` the message came from.

All logging data should be structured, avoiding large text output. It is
important that logging uses as few resources as possible - consider async
approaches and not requiring a response from the callback function.

Dart's [logging package](https://pub.dev/packages/logging) should be used as
appropriate, especially the level enumerations.

For the SQLite approach, refer to
[SQLite - The Error And Warning Log](https://sqlite.org/errlog.html).

## Open questions

{A checklist of open questions, mark each one off as they are answered}

## Investigation

{Investigation notes}

## Implementation plan

{Checklists and notes for the implementation work}

## Summary

{Dot points highlighting the work undertaken}
