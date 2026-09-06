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
import 'package:kmdb/kmdb.dart';

import '../../models/project.dart';
import '../../models/task.dart';
import '../../repositories/task_repository.dart';
import '../widgets/status_priority_chips.dart';
import 'task_detail_screen.dart';

/// Screen 3 of 6 — "Task list" (per project).
///
/// Demonstrates the secondary index (`TaskRepository.watchByProject`, spec
/// §16) and status/priority display.
class TaskListScreen extends StatefulWidget {
  /// Creates the [TaskListScreen] for [project] within [db].
  const TaskListScreen({required this.db, required this.project, super.key});

  /// The open database.
  final KmdbDatabase db;

  /// The project whose tasks this screen lists.
  final Project project;

  @override
  State<TaskListScreen> createState() => _TaskListScreenState();
}

class _TaskListScreenState extends State<TaskListScreen> {
  late final TaskRepository _repo = TaskRepository(widget.db);

  Future<void> _createTask() async {
    final titleController = TextEditingController();
    final descriptionController = TextEditingController();
    var priority = TaskPriority.medium;
    var status = TaskStatus.backlog;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('New task'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleController,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Title'),
              ),
              TextField(
                controller: descriptionController,
                decoration: const InputDecoration(labelText: 'Description'),
              ),
              DropdownButtonFormField<String>(
                initialValue: priority,
                decoration: const InputDecoration(labelText: 'Priority'),
                items: [
                  for (final p in TaskPriority.values)
                    DropdownMenuItem(value: p, child: Text(p)),
                ],
                onChanged: (v) => setDialogState(() => priority = v!),
              ),
              DropdownButtonFormField<String>(
                initialValue: status,
                decoration: const InputDecoration(labelText: 'Status'),
                items: [
                  for (final s in TaskStatus.values)
                    DropdownMenuItem(value: s, child: Text(s)),
                ],
                onChanged: (v) => setDialogState(() => status = v!),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );

    if (result != true || titleController.text.trim().isEmpty) return;
    final now = DateTime.now();
    await _repo.create(
      Task(
        id: '',
        projectId: widget.project.id,
        title: titleController.text.trim(),
        description: descriptionController.text.trim(),
        priority: priority,
        status: status,
        attachmentUris: const [],
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.project.name)),
      body: StreamBuilder<List<Task>>(
        stream: _repo.watchByProject(widget.project.id),
        builder: (context, snapshot) {
          final tasks = snapshot.data ?? const <Task>[];
          if (snapshot.connectionState == ConnectionState.waiting &&
              tasks.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }
          if (tasks.isEmpty) {
            return const Center(
              child: Text('No tasks yet. Tap + to create one.'),
            );
          }
          return ListView.builder(
            itemCount: tasks.length,
            itemBuilder: (context, index) {
              final task = tasks[index];
              return ListTile(
                title: Text(task.title),
                subtitle: task.description.isEmpty
                    ? null
                    : Text(task.description),
                trailing: Wrap(
                  spacing: 4,
                  children: [
                    StatusPriorityChip.priority(task.priority),
                    StatusPriorityChip.status(task.status),
                  ],
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        TaskDetailScreen(db: widget.db, taskId: task.id),
                  ),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'New task',
        onPressed: _createTask,
        child: const Icon(Icons.add),
      ),
    );
  }
}
