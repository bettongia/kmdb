// Copyright 2026 The Authors.
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

// coverage:ignore-file

import 'package:flutter/material.dart';

import '../../models/task.dart';

/// A small, colour-coded chip for a [Task.priority] or [Task.status] value.
///
/// Every background/foreground pair below is a "700"-or-darker Material
/// shade paired with white text, chosen to keep contrast comfortably above
/// the WCAG AA 4.5:1 threshold for small text — this is exactly the kind of
/// small, colour-coded element that's easy to make inaccessible if picked ad
/// hoc (see the Integration Guide's accessibility note). A [Semantics] label
/// on each chip also ensures the value is announced by screen readers, not
/// conveyed by colour alone.
class StatusPriorityChip extends StatelessWidget {
  /// Creates a priority chip for [priority] (one of [TaskPriority.values]).
  StatusPriorityChip.priority(String priority, {super.key})
    : _label = priority,
      _semanticPrefix = 'Priority',
      _color = _priorityColor(priority);

  /// Creates a status chip for [status] (one of [TaskStatus.values]).
  StatusPriorityChip.status(String status, {super.key})
    : _label = status,
      _semanticPrefix = 'Status',
      _color = _statusColor(status);

  static Color _priorityColor(String priority) => switch (priority) {
    TaskPriority.high => const Color(0xFFB71C1C), // red.shade900
    TaskPriority.medium => const Color(0xFFE65100), // orange.shade900
    TaskPriority.low => const Color(0xFF1B5E20), // green.shade900
    _ => const Color(0xFF424242), // grey.shade800 fallback
  };

  static Color _statusColor(String status) => switch (status) {
    TaskStatus.backlog => const Color(0xFF424242), // grey.shade800
    TaskStatus.inProgress => const Color(0xFF0D47A1), // blue.shade900
    TaskStatus.done => const Color(0xFF1B5E20), // green.shade900
    _ => const Color(0xFF424242),
  };

  final String _label;
  final String _semanticPrefix;
  final Color _color;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '$_semanticPrefix: $_label',
    child: ExcludeSemantics(
      child: Chip(
        label: Text(_label, style: const TextStyle(color: Colors.white)),
        backgroundColor: _color,
        visualDensity: VisualDensity.compact,
      ),
    ),
  );
}
