// Copyright 2026 The KMDB Authors
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

/// Breakpoint constants for the adaptive column layout.
///
/// Screens narrower than [multiColumn] pixels switch to a Navigator-based
/// push model instead of the side-by-side multi-column layout.
abstract final class LayoutBreakpoints {
  /// Minimum width (in logical pixels) for the multi-column layout.
  ///
  /// At or above this width, all visible columns are rendered side-by-side
  /// with draggable dividers. Below this width, navigation uses
  /// [Navigator.push] to move between column views.
  static const double multiColumn = 900.0;
}

/// Adaptive layout widget that switches between multi-column (wide) and
/// single-column Navigator-push (narrow) layouts.
///
/// On screens >= [LayoutBreakpoints.multiColumn] pixels wide, [wideBuilder]
/// is called and all content columns are shown side-by-side.
///
/// On narrower screens, [narrowBuilder] is called with a [NavigatorState]
/// that the caller can use to push/pop column views.
///
/// ## Usage
///
/// ```dart
/// AdaptiveColumnLayout(
///   wideBuilder: (context) => Row(children: [ColA(), ColB(), ColC()]),
///   narrowBuilder: (context) => ColA(),   // ColA pushes B/C on tap
/// )
/// ```
class AdaptiveColumnLayout extends StatelessWidget {
  /// Builder called on wide screens (>= [LayoutBreakpoints.multiColumn] px).
  final WidgetBuilder wideBuilder;

  /// Builder called on narrow screens (< [LayoutBreakpoints.multiColumn] px).
  final WidgetBuilder narrowBuilder;

  /// Creates an [AdaptiveColumnLayout].
  const AdaptiveColumnLayout({
    super.key,
    required this.wideBuilder,
    required this.narrowBuilder,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= LayoutBreakpoints.multiColumn;
        return isWide ? wideBuilder(context) : narrowBuilder(context);
      },
    );
  }
}

/// A draggable vertical divider between two resizable columns.
///
/// Drag horizontally to resize the left column. [onDrag] receives the delta
/// in logical pixels; the caller clamps the column width as appropriate.
class ColumnDivider extends StatelessWidget {
  /// Called with the horizontal drag delta in logical pixels.
  final ValueChanged<double> onDrag;

  /// Creates a [ColumnDivider].
  const ColumnDivider({super.key, required this.onDrag});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: (details) => onDrag(details.delta.dx),
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeLeftRight,
        child: Container(
          width: 8,
          color: Colors.transparent,
          child: Center(
            child: Container(
              width: 1,
              color: Theme.of(context).dividerColor,
            ),
          ),
        ),
      ),
    );
  }
}
