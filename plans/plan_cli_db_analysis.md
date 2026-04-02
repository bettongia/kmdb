# Database analysis utility in the CLI

**Status**: Open

**PR link**: {A link to the PR submitted for this plan}

## Problem statement

It can be useful to analyse key files in the database directory, including the
SSTable files, the MANIFEST file and WAL logs. Creating a `util` command in the
CLI that lets the user point at one of those files and get a human-readable
output can help with debugging issues.

This may create very large outputs so consider providing a `--summary` flag that
provides key metadata but only the count of records in files such as the WAL and
the SSTables.

Example CLI calls include:

```bash
# Display the details of an SSTable given by the filename (not the path)
# e.g. `kmdb mydb util sstable 00000000-019D47FDDE260000-019D4817C40A0000.sst`
kmdb mydb util sstable <file>

# Display the details of a WAL given by the filename (not the path)
# e.g. `kmdb mydb util wal wal-00027.log`
kmdb mydb util wal <file>

# The MANIFEST file doesn't need to be provided as there should only be one
kmdb mydb util manifest
```

This is a READ ONLY facility.

## Open questions

{A checklist of open questions, mark each one off as they are answered}

## Investigation

{Investigation notes}

## Implementation plan

{Checklists and notes for the implementation work}

## Summary

{Dot points highlighting the work undertaken}
