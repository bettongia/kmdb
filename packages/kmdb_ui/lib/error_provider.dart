// Copyright 2026 The Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// Application-level error notification provider.
///
/// [ErrorProvider] is used to surface operation errors to the user as
/// dismissable snackbars rather than silently injecting an
/// `{'error': '...'}` sentinel document into the document list.
///
/// ## Usage
///
/// 1. Register [ErrorProvider] in your `MultiProvider` tree.
/// 2. Place an [ErrorListener] widget below the `MaterialApp` so that a
///    [ScaffoldMessenger] is available.
/// 3. Call [show] from any provider or widget to post an error.
///
/// ```dart
/// context.read<ErrorProvider>().show('Failed to delete document');
/// ```
class ErrorProvider with ChangeNotifier {
  String? _lastError;
  int _version = 0;

  /// The most recent error message, or null if no error has been posted.
  String? get lastError => _lastError;

  /// An integer that increments on each new error.
  ///
  /// [ErrorListener] uses this to distinguish a second occurrence of the same
  /// message from an unchanged stale error.
  int get version => _version;

  /// Posts [message] as the current error and notifies listeners.
  ///
  /// [ErrorListener] will show this as a floating snackbar. Multiple calls
  /// with the same message string each increment [version], causing the
  /// snackbar to be re-shown.
  void show(String message) {
    _lastError = message;
    _version++;
    notifyListeners();
  }

  /// Clears the current error.
  ///
  /// Called after the snackbar has been shown so that subsequent rebuilds do
  /// not re-show the same error.
  void clear() {
    _lastError = null;
  }
}

/// A widget that listens to [ErrorProvider] and shows a floating snackbar for
/// each new error message.
///
/// Place this widget below a [Scaffold] ancestor — typically wrapping the body
/// of the app's root scaffold, or as a direct child of [MaterialApp.home].
///
/// ```dart
/// ErrorListener(child: Scaffold(body: ...))
/// ```
class ErrorListener extends StatefulWidget {
  /// The child widget tree.
  final Widget child;

  /// Creates an [ErrorListener].
  const ErrorListener({super.key, required this.child});

  @override
  State<ErrorListener> createState() => _ErrorListenerState();
}

class _ErrorListenerState extends State<ErrorListener> {
  int _lastSeenVersion = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Listen to ErrorProvider changes. Using addListener instead of
    // Consumer/watch because we never need to rebuild — we only need the
    // side-effect of showing a snackbar.
    final provider = context.read<ErrorProvider>();
    provider.removeListener(_onError);
    provider.addListener(_onError);
  }

  @override
  void dispose() {
    // Best-effort removal — the provider may outlive this state.
    try {
      context.read<ErrorProvider>().removeListener(_onError);
    } catch (_) {
      // ignore if provider is already gone
    }
    super.dispose();
  }

  void _onError() {
    final provider = context.read<ErrorProvider>();

    // Only show the snackbar if this is a genuinely new error version.
    if (provider.version <= _lastSeenVersion) return;
    _lastSeenVersion = provider.version;

    final message = provider.lastError;
    if (message == null || message.isEmpty) return;

    // Defer to the next frame so that the Scaffold messenger is fully mounted.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Theme.of(context).colorScheme.error,
          action: SnackBarAction(
            label: 'Dismiss',
            textColor: Theme.of(context).colorScheme.onError,
            onPressed: () => messenger.hideCurrentSnackBar(),
          ),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
