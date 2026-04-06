# CLI: Allow the deviceId to be changed

**Status**: Open

**PR link**: {A link to the PR submitted for this plan}

## Problem statement

When a database directory is copied we need to provide a CLI utility to generate
a new `deviceId` for the copy - otherwise sync will not work.

Consider the following example:

```sh
dart run ../../bin/kmdb.dart copydb_og put notes --value '{"title": "Original note"}'
dart run ../../bin/kmdb.dart copydb_og scan notes

# Use the filesystem to copy the database directory:
cp -R copydb_og copydb_copy

# We should see the original note:
dart run ../../bin/kmdb.dart copydb_copy scan notes

dart run ../../bin/kmdb.dart copydb_og info | jq '.deviceId'
dart run ../../bin/kmdb.dart copydb_copy info | jq '.deviceId'

# Configure a remote
dart run ../../bin/kmdb.dart copydb_og remote add origin --path $PWD/remote_mount/copydb_sync
dart run ../../bin/kmdb.dart copydb_copy remote add origin --path $PWD/remote_mount/copydb_sync

# When you now sync you'll see that it looks like the data is from the same deviceId
dart run ../../bin/kmdb.dart copydb_og sync
dart run ../../bin/kmdb.dart copydb_copy sync

# So create a new note and sync it
dart run ../../bin/kmdb.dart copydb_og put notes --value '{"title": "Original note - the sequel"}'
dart run ../../bin/kmdb.dart copydb_og scan notes
dart run ../../bin/kmdb.dart copydb_og sync

# Sync to the copy
dart run ../../bin/kmdb.dart copydb_copy sync

# The scan unfortunately displays only 1 note:
dart run ../../bin/kmdb.dart copydb_copy scan notes
```

Determine if generating a new `deviceId` will have side effects. If it does,
describe them; if not, implement the required change.

## Open questions

{A checklist of open questions, mark each one off as they are answered}

## Investigation

{Investigation notes}

## Implementation plan

{Checklists and notes for the implementation work}

## Summary

{Dot points highlighting the work undertaken}
