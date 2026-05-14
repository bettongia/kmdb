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

import 'app_provider.dart';

/// A modal overlay that blocks user interaction while a long-running operation
/// is in progress.
///
/// [AsyncOperationOverlay] wraps [child] and watches [AppProvider.isBusy].
/// When [AppProvider.isBusy] is true it renders a semi-transparent scrim with
/// a centred progress indicator and the [AppProvider.busyMessage] label,
/// preventing the user from triggering concurrent mutations.
///
/// All blocking operations (compact, verify, large import/restore, sync) must
/// go through [AppProvider.runBusy] to engage this overlay automatically.
///
/// ## Usage
///
/// ```dart
/// AsyncOperationOverlay(child: Scaffold(body: ...))
/// ```
class AsyncOperationOverlay extends StatelessWidget {
  /// The widget tree rendered behind the overlay.
  final Widget child;

  /// Creates an [AsyncOperationOverlay].
  const AsyncOperationOverlay({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final isBusy = context.select<AppProvider, bool>((p) => p.isBusy);
    final message = context.select<AppProvider, String>((p) => p.busyMessage);

    return Stack(
      children: [
        // The main content is always in the tree so that state is preserved.
        child,

        // Semi-transparent scrim + progress indicator while busy.
        if (isBusy)
          Positioned.fill(
            child: ColoredBox(
              // Use a dark scrim at 40% opacity so underlying content remains
              // visible while making clear that interaction is blocked.
              color: Colors.black.withValues(alpha: 0.4),
              child: Center(
                child: Card(
                  elevation: 8,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 24,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        if (message.isNotEmpty) ...[
                          const SizedBox(height: 16),
                          Text(
                            message,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
