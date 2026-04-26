# Work through CLI REPL issues

**Status**: Open

**PR link**: {A link to the PR submitted for this plan}

See also:

- [plan_cli_repl.md](completed/plan_cli_repl.md)
- [plan_cli.md](completed/plan_cli.md)

## Problem statement

Review the REPL implementation and determine any required testing improvements
and fixes.

A key aspect to this will be end-to-end testing to ensure that all the various
functions operate as expected. An initial start for this is
[cli_session_test.dart](../packages/kmdb_cli/test/e2e/cli_session_test.dart) and
that test should be enhanced with current functionality. A REPL-based end-to-end
test should also be developed and mirror the CLI version (omitting the
functionality not available in the REPL).

Calling `kmdb demodb` on a MacOS system using Z shell causes the error below. As
soon as the user types something in the REPL the exception is thrown. Ideally,
the REPL should handle all errors/exceptions by displaying a friendly error
message. Ideally, unrecoverable errors should also display an human-friendly
message and quit the REPL.

```
kmdb 0.1.0  •  demodb
Type .help for dot-commands or .quit to exit.
kmdb[demodb]> .Unhandled exception:
StdinException: Error setting terminal echo mode, OS Error: Bad file descriptor, errno = 9
#0      Stdin.echoMode= (dart:io-patch/stdio_patch.dart:93)
#1      TtyInputReader.readLine (package:kmdb_cli/src/repl/input_reader.dart:203)
<asynchronous suspension>
#2      ReplRunner._readMultiLine (package:kmdb_cli/src/repl/repl_runner.dart:164)
<asynchronous suspension>
#3      ReplRunner.run (package:kmdb_cli/src/repl/repl_runner.dart:110)
<asynchronous suspension>
#4      main (file:///Users/gonk/development/kmdb/packages/kmdb_cli/bin/kmdb.dart:20)
<asynchronous suspension>
```

We should consider maintaining a kmdb configuration directory for the user in
the location expected for the OS. This could store logs from the CLI and REPL
sessions sp that we can capture stack errors for debugging.

The KMDB CLI and REPL are admin tools for desktop users and target technical
users. We can assume a skill level that includes using the shell and tools like
the Postgres or SQLite CLI. We need to consider OS-level security that could
prevent access to parts of the file system.

## Open questions

{A checklist of open questions, mark each one off as they are answered}

## Investigation

{Investigation notes}

## Implementation plan

{Checklists and notes for the implementation work}

## Summary

{Dot points highlighting the work undertaken}
