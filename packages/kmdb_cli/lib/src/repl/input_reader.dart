// Copyright 2026 The KMDB Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:async';
import 'dart:collection';
import 'dart:io' as io;

/// Result of a single [InputReader.readLine] call.
enum ReadLineResult {
  /// The user pressed Enter; the line is available.
  line,

  /// The user pressed Ctrl+D on an empty line (EOF).
  eof,

  /// The user pressed Ctrl+C (interrupt).
  interrupt,
}

/// Outcome returned by [InputReader.readLine].
final class ReadLineOutcome {
  const ReadLineOutcome.line(this.value) : result = ReadLineResult.line;
  const ReadLineOutcome.eof() : result = ReadLineResult.eof, value = null;
  const ReadLineOutcome.interrupt()
    : result = ReadLineResult.interrupt,
      value = null;

  final ReadLineResult result;

  /// The entered text when [result] is [ReadLineResult.line]; `null` otherwise.
  final String? value;
}

/// Abstract line-editor interface used by [ReplRunner].
///
/// Two implementations exist:
/// - [TtyInputReader]: real raw-mode terminal reader used in production.
/// - [FakeInputReader]: pre-loaded line queue used in tests.
abstract class InputReader {
  /// Reads one line from the user, displaying [prompt] at the start.
  ///
  /// Supports history navigation (up/down arrows) using the entries supplied
  /// via [setHistory], and tab completion via the [completer] callback.
  Future<ReadLineOutcome> readLine(
    String prompt, {
    CompletionCallback? completer,
  });

  /// Replaces the history list used for up/down-arrow navigation.
  ///
  /// Called by [ReplRunner] after every successful entry so the new entry is
  /// immediately available on the next readLine call.
  void setHistory(List<String> history);

  /// Releases any resources held by this reader.
  ///
  /// Must be called once when the owning REPL session ends. Safe to call if
  /// [readLine] was never invoked.
  Future<void> dispose() async {}
}

/// Callback invoked when the user presses Tab.
///
/// Receives the current line [text] and cursor [position] (byte offset into
/// [text]). Returns a (possibly empty) list of completion candidates.
typedef CompletionCallback =
    Future<List<String>> Function(String text, int position);

// ── ByteQueue ─────────────────────────────────────────────────────────────────

/// Async single-consumer byte queue that bridges a [StreamSubscription] to
/// point-in-time [next] / [nextTimeout] reads without creating and tearing
/// down stream subscriptions on every byte.
///
/// [TtyInputReader] opens one [io.stdin] subscription per [InputReader.readLine]
/// call and drains every incoming chunk into this queue. The key reader then
/// pulls individual bytes via [next] and [nextTimeout] without touching the
/// underlying stream, avoiding the macOS-native bug where cancelling the stdin
/// subscription closes fd 0 and makes subsequent `ioctl` calls fail with EBADF.
///
/// Only one consumer may await [next] or [nextTimeout] at a time.
final class ByteQueue {
  final _pending = Queue<int>();
  Completer<int>? _waiter;
  bool _closed = false;

  /// Delivers [byte] to a waiting [next] / [nextTimeout] call, or enqueues it.
  ///
  /// No-ops if the queue has been [close]d.
  void add(int byte) {
    if (_closed) return;
    if (_waiter != null) {
      _waiter!.complete(byte);
      _waiter = null;
    } else {
      _pending.add(byte);
    }
  }

  /// Signals EOF; any pending [next] call receives the EOF sentinel (`0x04`).
  ///
  /// Idempotent — safe to call more than once.
  void close() {
    if (_closed) return;
    _closed = true;
    _waiter?.complete(0x04);
    _waiter = null;
  }

  /// Returns the next byte, waiting until one is available.
  ///
  /// Returns `0x04` (Ctrl+D / EOF sentinel) if the queue has been [close]d.
  Future<int> next() async {
    if (_pending.isNotEmpty) return _pending.removeFirst();
    if (_closed) return 0x04;
    _waiter = Completer<int>();
    return _waiter!.future;
  }

  /// Returns the next byte, or `null` if [timeout] elapses before one arrives.
  Future<int?> nextTimeout(Duration timeout) async {
    if (_pending.isNotEmpty) return _pending.removeFirst();
    if (_closed) return null;
    _waiter = Completer<int>();
    try {
      return await _waiter!.future.timeout(timeout);
    } on TimeoutException {
      _waiter = null;
      return null;
    }
  }
}

// ── TtyInputReader ────────────────────────────────────────────────────────────

// coverage:ignore-start
// TtyInputReader requires a real terminal (raw-mode stdin) and cannot be
// exercised in headless unit tests. FakeInputReader is used instead.

/// Raw-mode terminal line editor.
///
/// Puts stdin into raw mode (no echo, no line buffering) and handles:
/// - Printable character insertion at the cursor position.
/// - Left/right arrow and Ctrl+A/E for cursor movement.
/// - Backspace and Delete for character removal.
/// - Up/down arrow for history navigation.
/// - Tab for context-aware completion.
/// - Enter to submit the line.
/// - Ctrl+D on an empty line for EOF.
/// - Ctrl+C for interrupt.
///
/// A single [io.stdin] subscription is opened on the first [readLine] call and
/// kept alive for the full REPL session. All byte reads are routed through a
/// shared [ByteQueue]. This avoids the macOS-native behaviour where
/// cancelling and re-opening the stdin subscription throws "Stream has already
/// been listened to" (single-subscription stream) and/or closes fd 0, causing
/// subsequent `ioctl` calls to fail with EBADF. Call [dispose] once when the
/// REPL session ends.
final class TtyInputReader implements InputReader {
  /// Creates a [TtyInputReader] that writes to [output] (defaults to stdout).
  TtyInputReader({io.IOSink? output}) : _out = output ?? io.stdout;

  final io.IOSink _out;
  List<String> _history = const [];

  // Shared subscription and queue, opened lazily on the first readLine call
  // and kept alive across calls. io.stdin is a single-subscription stream —
  // cancelling and re-listening throws "Stream has already been listened to".
  ByteQueue? _queue;
  StreamSubscription<List<int>>? _sub;

  void _ensureSubscribed() {
    if (_sub != null) return;
    _queue = ByteQueue();
    _sub = io.stdin.listen(
      (chunk) {
        for (final b in chunk) {
          _queue!.add(b);
        }
      },
      onDone: _queue!.close,
      onError: (_) => _queue!.close(),
      cancelOnError: false,
    );
  }

  @override
  Future<void> dispose() async {
    await _sub?.cancel();
    _queue?.close();
    _sub = null;
    _queue = null;
  }

  @override
  void setHistory(List<String> history) {
    _history = List.unmodifiable(history);
  }

  @override
  Future<ReadLineOutcome> readLine(
    String prompt, {
    CompletionCallback? completer,
  }) async {
    final buf = _LineBuffer();
    // _histIndex == _history.length means "current (unsaved) line".
    var histIndex = _history.length;
    String savedLine = '';

    _out.write(prompt);

    // Lazily open the shared stdin subscription. io.stdin is a
    // single-subscription stream — re-listening after cancel throws "Stream
    // has already been listened to", so the subscription must live for the
    // full session and be closed only via dispose().
    _ensureSubscribed();
    final queue = _queue!;

    try {
      io.stdin
        ..echoMode = false
        ..lineMode = false;
    } on io.StdinException {
      // Terminal mode setup failed (e.g. stdin is not a real TTY).
      // Rethrow so ReplRunner can show a friendly message; the subscription
      // is cleaned up by dispose() when the session ends.
      rethrow;
    }

    try {
      while (true) {
        final key = await _readKey(queue);

        switch (key.type) {
          case _KeyType.char:
            buf.insert(key.char!);
            _redraw(prompt, buf);

          case _KeyType.enter:
            _out.writeln();
            return ReadLineOutcome.line(buf.toString());

          case _KeyType.ctrlD:
            if (buf.isEmpty) {
              _out.writeln();
              return const ReadLineOutcome.eof();
            }
            // Ctrl+D mid-line: delete char under cursor (like forward-delete).
            buf.deleteForward();
            _redraw(prompt, buf);

          case _KeyType.ctrlC:
            _out.writeln();
            return const ReadLineOutcome.interrupt();

          case _KeyType.backspace:
            buf.deleteBack();
            _redraw(prompt, buf);

          case _KeyType.delete:
            buf.deleteForward();
            _redraw(prompt, buf);

          case _KeyType.left:
            buf.moveLeft();
            _redrawCursorOnly(prompt, buf);

          case _KeyType.right:
            buf.moveRight();
            _redrawCursorOnly(prompt, buf);

          case _KeyType.home:
            buf.moveHome();
            _redrawCursorOnly(prompt, buf);

          case _KeyType.end:
            buf.moveEnd();
            _redrawCursorOnly(prompt, buf);

          case _KeyType.ctrlK:
            buf.killToEnd();
            _redraw(prompt, buf);

          case _KeyType.ctrlU:
            buf.killToHome();
            _redraw(prompt, buf);

          case _KeyType.up:
            if (histIndex > 0) {
              if (histIndex == _history.length) savedLine = buf.toString();
              histIndex--;
              buf.set(_history[histIndex]);
            }
            _redraw(prompt, buf);

          case _KeyType.down:
            if (histIndex < _history.length) {
              histIndex++;
              buf.set(
                histIndex == _history.length ? savedLine : _history[histIndex],
              );
            }
            _redraw(prompt, buf);

          case _KeyType.tab:
            if (completer != null) {
              await _handleTab(prompt, buf, completer);
            }

          case _KeyType.unknown:
            break; // ignore unrecognised sequences
        }
      }
    } finally {
      // Restore terminal mode only. The subscription lives for the full
      // session and is released by dispose() — cancelling it here would
      // prevent re-use on the next readLine call ("Stream has already been
      // listened to").
      try {
        io.stdin.echoMode = true;
      } catch (_) {}
      try {
        io.stdin.lineMode = true;
      } catch (_) {}
    }
  }

  // ── Display helpers ─────────────────────────────────────────────────────────

  /// Redraws the full line (prompt + buffer contents) and positions the cursor.
  void _redraw(String prompt, _LineBuffer buf) {
    final text = buf.toString();
    final cursor = buf.cursor;
    // \r: move to column 0; \x1b[K: erase to end of line.
    _out.write('\r\x1b[K$prompt$text');
    // Move cursor left from end-of-text to cursor position.
    final charsAfterCursor = text.length - cursor;
    if (charsAfterCursor > 0) {
      _out.write('\x1b[${charsAfterCursor}D');
    }
  }

  /// Repositions the cursor without repainting the text.
  void _redrawCursorOnly(String prompt, _LineBuffer buf) {
    final text = buf.toString();
    final cursor = buf.cursor;
    final charsAfterCursor = text.length - cursor;
    _out.write('\r\x1b[K$prompt$text');
    if (charsAfterCursor > 0) {
      _out.write('\x1b[${charsAfterCursor}D');
    }
  }

  // ── Tab completion ──────────────────────────────────────────────────────────

  Future<void> _handleTab(
    String prompt,
    _LineBuffer buf,
    CompletionCallback completer,
  ) async {
    final candidates = await completer(buf.toString(), buf.cursor);
    if (candidates.isEmpty) return;

    if (candidates.length == 1) {
      // Single match: complete the current word.
      final completed = _applyCompletion(
        buf.toString(),
        buf.cursor,
        candidates[0],
      );
      buf.set(completed);
      _redraw(prompt, buf);
      return;
    }

    // Multiple matches: find common prefix and display options.
    final prefix = _commonPrefix(candidates);
    if (prefix.isNotEmpty) {
      final current = buf.toString().substring(0, buf.cursor);
      final lastSpace = current.lastIndexOf(' ');
      final wordStart = lastSpace + 1;
      final before = buf.toString().substring(0, wordStart);
      final after = buf.toString().substring(buf.cursor);
      buf.set('$before$prefix$after');
      buf.setCursor(wordStart + prefix.length);
      _redraw(prompt, buf);
    }

    // Show all candidates on the next line.
    _out.writeln();
    _out.writeln(candidates.join('  '));
    _redraw(prompt, buf);
  }

  String _applyCompletion(String text, int cursor, String candidate) {
    final before = text.substring(0, cursor);
    final after = text.substring(cursor);
    final lastSpace = before.lastIndexOf(' ');
    final prefix = before.substring(0, lastSpace + 1);
    return '$prefix$candidate$after';
  }

  String _commonPrefix(List<String> words) {
    if (words.isEmpty) return '';
    var prefix = words[0];
    for (final w in words.skip(1)) {
      while (!w.startsWith(prefix)) {
        prefix = prefix.substring(0, prefix.length - 1);
        if (prefix.isEmpty) return '';
      }
    }
    return prefix;
  }

  // ── Key reader ──────────────────────────────────────────────────────────────

  Future<_Key> _readKey(ByteQueue queue) async {
    final b = await _readByte(queue);

    // Escape sequence
    if (b == 0x1b) {
      // Try to read '[' within a short timeout.
      final next = await _readByteTimeout(queue, 50);
      if (next == null) return const _Key(_KeyType.unknown);

      if (next == 0x5b) {
        // CSI sequence: \x1b[
        final ch = await _readByteTimeout(queue, 50);
        if (ch == null) return const _Key(_KeyType.unknown);

        switch (ch) {
          case 0x41:
            return const _Key(_KeyType.up);
          case 0x42:
            return const _Key(_KeyType.down);
          case 0x43:
            return const _Key(_KeyType.right);
          case 0x44:
            return const _Key(_KeyType.left);
          case 0x48:
            return const _Key(_KeyType.home);
          case 0x46:
            return const _Key(_KeyType.end);
          case 0x31: // \x1b[1~  Home
            await _consumeUntilTilde(queue);
            return const _Key(_KeyType.home);
          case 0x33: // \x1b[3~  Delete
            await _consumeUntilTilde(queue);
            return const _Key(_KeyType.delete);
          case 0x34: // \x1b[4~  End
            await _consumeUntilTilde(queue);
            return const _Key(_KeyType.end);
          default:
            return const _Key(_KeyType.unknown);
        }
      }

      if (next == 0x4f) {
        // SS3 sequence: \x1bO
        final ch = await _readByteTimeout(queue, 50);
        switch (ch) {
          case 0x48:
            return const _Key(_KeyType.home);
          case 0x46:
            return const _Key(_KeyType.end);
        }
      }

      return const _Key(_KeyType.unknown);
    }

    // Control characters
    switch (b) {
      case 0x0d: // CR (\r) — Enter
      case 0x0a: // LF (\n) — Enter
        return const _Key(_KeyType.enter);
      case 0x7f: // DEL — Backspace
      case 0x08: // BS  — Backspace
        return const _Key(_KeyType.backspace);
      case 0x04:
        return const _Key(_KeyType.ctrlD);
      case 0x03:
        return const _Key(_KeyType.ctrlC);
      case 0x01:
        return const _Key(_KeyType.home);
      case 0x05:
        return const _Key(_KeyType.end);
      case 0x0b:
        return const _Key(_KeyType.ctrlK);
      case 0x15:
        return const _Key(_KeyType.ctrlU);
      case 0x09:
        return const _Key(_KeyType.tab);
    }

    // Printable ASCII and basic Latin-1.
    if (b >= 0x20) {
      return _Key.char(String.fromCharCode(b));
    }

    return const _Key(_KeyType.unknown);
  }

  Future<int> _readByte(ByteQueue queue) => queue.next();

  Future<int?> _readByteTimeout(ByteQueue queue, int ms) =>
      queue.nextTimeout(Duration(milliseconds: ms));

  Future<void> _consumeUntilTilde(ByteQueue queue) async {
    while (true) {
      final b = await _readByteTimeout(queue, 50);
      if (b == null || b == 0x7e) return; // 0x7e == '~'
    }
  }
}

// coverage:ignore-end

// ── FakeInputReader ───────────────────────────────────────────────────────────

/// A test-only [InputReader] that emits lines from a pre-loaded queue.
///
/// Returns [ReadLineOutcome.eof] when the queue is exhausted.
final class FakeInputReader implements InputReader {
  /// Creates a [FakeInputReader] that will emit [lines] in order.
  FakeInputReader(Iterable<String> lines) : _queue = [...lines];

  final List<String> _queue;

  /// Lines that have been "submitted" (for test assertions).
  final List<String> submitted = [];

  @override
  void setHistory(List<String> history) {}

  @override
  Future<ReadLineOutcome> readLine(
    String prompt, {
    CompletionCallback? completer,
  }) async {
    if (_queue.isEmpty) return const ReadLineOutcome.eof();
    final line = _queue.removeAt(0);
    submitted.add(line);
    return ReadLineOutcome.line(line);
  }

  @override
  Future<void> dispose() async {}
}

// ── Internal types (tty-only; not reachable from FakeInputReader) ─────────────

// coverage:ignore-start

enum _KeyType {
  char,
  enter,
  backspace,
  delete,
  left,
  right,
  up,
  down,
  home,
  end,
  tab,
  ctrlD,
  ctrlC,
  ctrlK,
  ctrlU,
  unknown,
}

final class _Key {
  const _Key(this.type) : char = null;
  const _Key.char(this.char) : type = _KeyType.char;
  final _KeyType type;
  final String? char;
}

// ── Line buffer ───────────────────────────────────────────────────────────────

/// Mutable line buffer with a cursor position for in-line editing.
final class _LineBuffer {
  final _buf = StringBuffer();
  String _text = '';
  int _cursor = 0;

  bool get isEmpty => _text.isEmpty;
  int get cursor => _cursor;

  void insert(String ch) {
    _text = _text.substring(0, _cursor) + ch + _text.substring(_cursor);
    _cursor++;
  }

  void deleteBack() {
    if (_cursor == 0) return;
    _text = _text.substring(0, _cursor - 1) + _text.substring(_cursor);
    _cursor--;
  }

  void deleteForward() {
    if (_cursor >= _text.length) return;
    _text = _text.substring(0, _cursor) + _text.substring(_cursor + 1);
  }

  void moveLeft() {
    if (_cursor > 0) _cursor--;
  }

  void moveRight() {
    if (_cursor < _text.length) _cursor++;
  }

  void moveHome() => _cursor = 0;
  void moveEnd() => _cursor = _text.length;

  void killToEnd() => _text = _text.substring(0, _cursor);
  void killToHome() {
    _text = _text.substring(_cursor);
    _cursor = 0;
  }

  void set(String text) {
    _text = text;
    _cursor = text.length;
  }

  void setCursor(int pos) {
    _cursor = pos.clamp(0, _text.length);
  }

  @override
  String toString() {
    _buf.clear();
    _buf.write(_text);
    return _buf.toString();
  }
}

// coverage:ignore-end
