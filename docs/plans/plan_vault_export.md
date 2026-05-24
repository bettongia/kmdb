# Vault file export

**Status**: Open

**PR link**: {A link to the PR submitted for this plan}

## Problem statement

The CLI should include a `vault export` command that will export a specific
vault file to the path given in the `--output` parameter.

- If `--output` is a file path, the vault file will be exported to that path.
- If `--output` is a directory, the vault file will be placed into the requested
  directory and the file will be named based on the `originalName` property in
  `metadata.json` - if the `originalName` property does not exist, the vault
  file with be exported to the path with a file name of `blob`.

Note that the CLI usage indicates that the user can run `vault help` but this
fails on a database where Vault has not been initialised
(`Error: Vault is not available for this database. Vault storage is initialised automatically when files are first ingested via "vault ingest" or "--import".`).
This needs to be fixed as part of this work.

## Open questions

{A checklist of open questions, mark each one off as they are answered}

## Investigation

{Investigation notes}

## Implementation plan

{Checklists and notes for the implementation work}

## Summary

{Dot points highlighting the work undertaken}
