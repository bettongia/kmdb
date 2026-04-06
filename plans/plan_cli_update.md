# CLI: Support updates

**Status**: Open

**PR link**: {A link to the PR submitted for this plan}

## Problem statement

In the KMDB CLI, updating an existing document is partially supported but not as
a first-class "update" or "patch" command.

Current Support:

1. Full Document Replacement (via import): The import command is currently the
   only way to update an existing document by its ID. It requires the input JSON
   to have an `_id` field and defaults to a replace strategy.

   ```sh
   # Overwrites the document with ID '019...' with the provided fields 2
   echo '{"`_id`": "019...", "title": "Updated Title", "status": "done"}' | kmdb mydb import notes
   ```

1. The `put` command is actually an "Insert": Although named put (which usually
   implies upsert), the current CLI implementation always generates a new UUIDv7
   key and replaces any `_id` provided in the input. Therefore, it cannot be
   used to update existing records.
1. No Partial Updates: There is currently no way to perform a partial update
   (patching specific fields) without providing the entire document.

To provide comprehensive update functionality, I would suggest the following
changes:

1. Fix `put` to respect `_id` (True Upsert) Modify PutCommand to check for an
   existing `_id`. If present, it should use that ID instead of generating a new
   one. This would turn put into a standard upsert command.

   ```dart
   // Proposed change in PutCommand.execute
   final key = doc['_id']?.toString() ?? const UuidV7KeyGenerator().next();
   doc['_id'] = key;
   await ctx.store.put(collection, key, ValueCodec.encode(doc));
   ```

1. Add a `patch` Command (Partial Updates) Introduce a `patch` command that
   merges new fields into an existing document. This would leverage the
   library's KmdbCollection.update capability.

- Usage: `kmdb <db> patch <collection> <id> --value '{"status": "done"}'`
- Workflow:
  1.  Fetch the existing document by `<id>`.
  2.  Merge the JSON from `--value` into the existing map.
  3.  Write the merged document back to the store.

3. Add a query-update Command (Batch Updates) For more advanced scenarios, a
   command could update all documents matching a filter: \_ Usage:
   `kmdb <db> update <collection> --filter '{"field": "active", "op": "eq", "value": false}' --set '{"archived": true}'`

## Open questions

{A checklist of open questions, mark each one off as they are answered}

## Investigation

{Investigation notes}

## Implementation plan

{Checklists and notes for the implementation work}

## Summary

{Dot points highlighting the work undertaken}
