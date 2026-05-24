# Fix REPL crash on first keypress (StdinException EBADF)

**Status**: Complete

**PR link**: {A link to the PR submitted for this plan}

See also:

- [plan_cli_repl.md](completed/plan_cli_repl.md)
- [plan_cli.md](completed/plan_cli.md)
- [plan_cli_config_dir.md](plan_cli_config_dir.md)

## Problem statement

The REPL crashes with an unhandled `StdinException` on the first keypress when
run from a compiled native binary on macOS with Z shell. The crash produces a
raw stack trace rather than a user-friendly error message.

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

(`demodb` is a database path, not a command — the REPL starts when `stdin` is a
terminal and no inline command is given, treating the first positional argument as
a database path.)

The REPL should handle all errors and exceptions by displaying a friendly error
message. Unrecoverable errors should display a human-friendly message and quit
the REPL cleanly.

The KMDB CLI and REPL are admin tools targeting technical desktop users (skill
level: shell, psql, sqlite3). OS-level security restrictions on file system
access should be considered.

A separate plan ([plan_cli_config_dir.md](plan_cli_config_dir.md)) covers the
per-user KMDB configuration directory for logs and crash capture.

## Open questions

- [x] Does the bug reproduce with a compiled native binary in a real terminal?
  **Yes** — confirmed with `dart build cli bin/kmdb.dart` run from macOS
  Terminal.app Z shell.

## Investigation

### Root cause: stdin stream subscription lifecycle

The crash is caused by `TtyInputReader._readByte` (
[input_reader.dart:384–389](../packages/kmdb_cli/lib/src/repl/input_reader.dart))
reopening the `io.stdin` stream on every byte read:

```dart
Future<int> _readByte() async {
  await for (final chunk in io.stdin) {
    if (chunk.isNotEmpty) return chunk[0]; // returns inside the loop
  }
  return 0x04;
}
```

`io.stdin` in Dart native is a single-subscription stream. `await for` creates a
`StreamSubscription`. When `return chunk[0]` executes, Dart cancels that
subscription. On macOS native, **cancelling the stdin stream subscription closes
the underlying file descriptor (fd 0)**. Any subsequent `ioctl` call on stdin
— including the `echoMode =` and `lineMode =` setters — then fails with
`EBADF (errno = 9)`.

Sequence after the first keypress:

1. `_readByte()` returns the byte and cancels the subscription → fd 0 is closed.
2. The key is dispatched; `readLine` loops back to call `_readKey()` again.
3. `_readByte()` (or `_readByteTimeout` via `io.stdin.first`) tries to
   re-subscribe to the now-closed stdin → throws `StateError` or
   `StdinException`.
4. The exception propagates up through the `while (true)` loop, triggering the
   `finally` block.
5. The `finally` block attempts `echoMode = true` on the closed fd →
   `StdinException: Bad file descriptor` escapes `readLine` entirely.
6. `ReplRunner.run` has no catch-all, so the exception reaches `main` as an
   unhandled exception with a raw stack trace.

Note: `echoMode = false` / `lineMode = false` are set **before** the `try`
block (lines 114–116), so they are unprotected as well.

### Fix approach

Replace the per-call `await for` / `io.stdin.first` pattern with a single stdin
subscription held for the full lifetime of each `readLine` call.

A private `_ByteQueue` helper (within the existing `coverage:ignore` block)
backed by a `Queue<int>` and a `Completer<int>?` waiter:

- `void add(int byte)` — satisfies a pending waiter or enqueues.
- `void close()` — signals EOF to any pending waiter.
- `Future<int> next()` — returns the next byte, waiting if the queue is empty.
- `Future<int?> nextTimeout(Duration)` — like `next()` but returns `null` on
  timeout, using `Future.timeout`.

`readLine` opens one `io.stdin.listen(...)` at the top of the method, feeding
every byte into a `_ByteQueue`. `_readByte` and `_readByteTimeout` are refactored
to accept a `_ByteQueue` and pull from it; they no longer reference `io.stdin`
directly. The subscription is cancelled in the `finally` block, after restoring
`echoMode`/`lineMode`.

Both the initial `echoMode = false` assignment (lines 114–116) and the `finally`
restore (lines 202–205) should be individually wrapped in `try/catch` to prevent
a broken fd from producing an unhandled exception.

### Top-level error handling

`ReplRunner.run` catches `QuitException` but nothing else. An unhandled exception
from `_readMultiLine` or `_dispatchLine` should be caught, a friendly message
printed to stderr, and exit code 1 returned — no raw stack trace.

### REPL invocation model: implicit vs explicit subcommand

The REPL currently starts implicitly when `stdin` is a terminal and no inline
command is given (`cli_runner.dart:334–336`). This matches the `psql` /
`sqlite3` convention and is the expected pattern for the target audience.

An explicit `kmdb repl <path>` subcommand was considered. It would eliminate the
TTY-detection heuristic and make the REPL surface fully discoverable via
`kmdb help`. The downside is verbosity for the most common interactive use case,
and it would be a breaking interface change.

The implicit approach is kept for now. The only currently reserved word at the
db-path position is `help` (special-cased in `cli_runner.dart:215`). **This
decision should be revisited if a second global command (one that needs no
db-path) is added**, at which point the growing implicit reserved-word list
becomes a genuine user-facing problem and a subcommand refactor is warranted.

### Key files

| File | Relevance |
|------|-----------|
| `packages/kmdb_cli/lib/src/repl/input_reader.dart` | `TtyInputReader` — byte reading; entire class under `coverage:ignore` |
| `packages/kmdb_cli/lib/src/repl/repl_runner.dart` | `ReplRunner.run` — outer loop; needs catch-all handler |

## Implementation plan

### 1 — Add `_ByteQueue` to `input_reader.dart`

- [x] Inside the existing `// coverage:ignore-start` region, add a private
  `_ByteQueue` class with fields `Queue<int> _pending`,
  `Completer<int>? _waiter`, `bool _closed = false`.
- [x] Implement `void add(int byte)`: complete `_waiter` if set, else enqueue.
- [x] Implement `void close()`: set `_closed = true`; complete `_waiter` with
  `0x04` (EOF sentinel) if set.
- [x] Implement `Future<int> next()`: dequeue immediately if non-empty;
  otherwise set `_waiter` and await it.
- [x] Implement `Future<int?> nextTimeout(Duration timeout)`: same as `next()`
  but wraps the await in `.timeout(timeout, onTimeout: () { _waiter = null; return null; })`.

### 2 — Refactor `TtyInputReader.readLine`

- [x] At the top of `readLine`, open a single stdin subscription draining into
  a `ByteQueue`.
- [x] Wrap the `echoMode = false` / `lineMode = false` assignment in
  `try/catch (StdinException)` — on failure, cancel the subscription, close
  the queue, and rethrow so `ReplRunner` can show a friendly message.
- [x] Refactor `_readByte` and `_readByteTimeout` to accept a `ByteQueue`
  parameter; they no longer reference `io.stdin` directly.
- [x] Update all call sites in `_readKey` and `_consumeUntilTilde` to pass
  the queue.
- [x] In the `finally` block: restore `echoMode` and `lineMode` first (each in
  its own `try/catch`), then cancel the subscription and close the queue.
  Restoring before cancellation avoids the macOS-native behaviour where
  `sub.cancel()` closes fd 0 before the `ioctl` calls can succeed.

### 3 — Top-level error handling in `ReplRunner`

- [x] In `ReplRunner.run`, add `catch (e)` after `on QuitException`:
  prints a friendly error line to `_errSink()` and returns exit code 1.

### 4 — Tests

- [x] Added `packages/kmdb_cli/test/repl/byte_queue_test.dart` with 12 unit
  tests for `ByteQueue` covering: enqueue before wait, wait before enqueue,
  FIFO ordering, timeout, close while waiting, close with pending bytes,
  idempotent close, add after close, and queue reuse after timeout.
- [x] Added `unhandled errors` group to `repl_runner_test.dart` with a
  `_ThrowingInputReader` that throws `StdinException`, asserting exit code 1
  and a friendly stderr message.
- [x] All 806 tests pass (`cd packages/kmdb_cli && dart test`).
- [x] Coverage unchanged at 78.3% — pre-existing baseline caused by
  `cli_runner.dart` (23%) and `spinner.dart` (0%), both untouched by this work.

### 5 — Documentation

- [x] Updated `TtyInputReader` doc comment to describe the single-subscription
  model and the EBADF root cause.
- [x] Updated `ReplRunner` doc comment to note the catch-all error handling
  contract.

## Summary

- Identified root cause: `TtyInputReader._readByte` used `await for` on `io.stdin`, creating and cancelling a stream subscription on every byte. On macOS native, cancelling the subscription closes fd 0, making subsequent `ioctl` calls (`echoMode=`, `lineMode=`) fail with EBADF — producing the unhandled `StdinException` crash on the first keypress.
- Added `ByteQueue`: a public, fully-tested async byte queue backed by a `Queue<int>` and a single `Completer<int>?` waiter, bridging a persistent stdin subscription to point-in-time byte reads.
- Refactored `TtyInputReader.readLine` to open one `io.stdin.listen(...)` subscription for the full duration of each call. `_readByte`, `_readByteTimeout`, `_readKey`, and `_consumeUntilTilde` now pull from the queue rather than re-subscribing. Terminal mode is restored before the subscription is cancelled to avoid the fd-close race.
- Added `try/catch` guards around both the `echoMode = false` setup and the `finally` restore so a broken fd surfaces a typed exception rather than crashing.
- Added a catch-all `catch (e)` handler in `ReplRunner.run` so any unhandled exception (including `StdinException`) prints a friendly message to stderr and returns exit code 1 instead of propagating a raw stack trace to `main`.
- Added 12 unit tests for `ByteQueue` (`byte_queue_test.dart`) and a `StdinException` error-path test in `repl_runner_test.dart`. All 806 tests pass.
