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

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:kmdb/kmdb.dart';
import 'package:path/path.dart' as p;

import '../../models/task.dart';
import '../../models/task_comment.dart';
import '../../repositories/attachment_repository.dart';
import '../../repositories/comment_repository.dart';
import '../../repositories/task_repository.dart';
import '../widgets/status_priority_chips.dart';

/// Screen 4 of 6 — "Task detail/edit".
///
/// Demonstrates field editing (`TaskRepository.update`), vault attachment
/// ingest/get (`AttachmentRepository`, spec §24), and the `taskComments`
/// sub-collection (`CommentRepository`) alongside its FTS index.
class TaskDetailScreen extends StatefulWidget {
  /// Creates the [TaskDetailScreen] for [taskId] within [db].
  const TaskDetailScreen({required this.db, required this.taskId, super.key});

  /// The open database.
  final KmdbDatabase db;

  /// The task being viewed/edited.
  final String taskId;

  @override
  State<TaskDetailScreen> createState() => _TaskDetailScreenState();
}

class _TaskDetailScreenState extends State<TaskDetailScreen> {
  late final TaskRepository _taskRepo = TaskRepository(widget.db);
  late final AttachmentRepository _attachmentRepo = AttachmentRepository(
    widget.db,
    _taskRepo,
  );
  late final CommentRepository _commentRepo = CommentRepository(widget.db);

  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _attachPathController = TextEditingController();
  final _commentController = TextEditingController();

  Task? _lastLoaded;
  String? _attachError;

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _attachPathController.dispose();
    _commentController.dispose();
    super.dispose();
  }

  void _syncControllers(Task task) {
    if (_lastLoaded?.id == task.id &&
        _lastLoaded?.title == task.title &&
        _lastLoaded?.description == task.description) {
      return;
    }
    _lastLoaded = task;
    _titleController.text = task.title;
    _descriptionController.text = task.description;
  }

  Future<void> _saveFields(Task current) async {
    await _taskRepo.update(
      current.copyWith(
        title: _titleController.text.trim(),
        description: _descriptionController.text.trim(),
      ),
    );
  }

  Future<void> _changePriority(Task current, String priority) =>
      _taskRepo.update(current.copyWith(priority: priority));

  Future<void> _changeStatus(Task current, String status) =>
      _taskRepo.update(current.copyWith(status: status));

  Future<void> _attachFile(Task current) async {
    setState(() => _attachError = null);
    final path = _attachPathController.text.trim();
    if (path.isEmpty) return;
    try {
      final bytes = Uint8List.fromList(await File(path).readAsBytes());
      await _attachmentRepo.attach(
        task: current,
        bytes: bytes,
        originalName: p.basename(path),
      );
      _attachPathController.clear();
    } on FileSystemException catch (e) {
      setState(() => _attachError = 'Could not read "$path": ${e.message}');
    }
  }

  Future<void> _addComment(Task current) async {
    final body = _commentController.text.trim();
    if (body.isEmpty) return;
    await _commentRepo.add(
      TaskComment(
        id: '',
        taskId: current.id,
        author: 'You',
        body: body,
        createdAt: DateTime.now(),
      ),
    );
    _commentController.clear();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Task?>(
      stream: _taskRepo.watchTask(widget.taskId),
      builder: (context, snapshot) {
        final task = snapshot.data;
        if (task == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Task')),
            body: const Center(child: Text('Task not found (deleted?)')),
          );
        }
        _syncControllers(task);

        return Scaffold(
          appBar: AppBar(
            title: Text(task.title),
            actions: [
              IconButton(
                tooltip: 'Delete task',
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  await _taskRepo.delete(task.id);
                  if (context.mounted) Navigator.of(context).pop();
                },
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextField(
                controller: _titleController,
                decoration: const InputDecoration(labelText: 'Title'),
                onSubmitted: (_) => _saveFields(task),
                onEditingComplete: () => _saveFields(task),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _descriptionController,
                decoration: const InputDecoration(labelText: 'Description'),
                maxLines: 3,
                onSubmitted: (_) => _saveFields(task),
                onEditingComplete: () => _saveFields(task),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: task.priority,
                      decoration: const InputDecoration(labelText: 'Priority'),
                      items: [
                        for (final priority in TaskPriority.values)
                          DropdownMenuItem(
                            value: priority,
                            child: StatusPriorityChip.priority(priority),
                          ),
                      ],
                      onChanged: (v) => _changePriority(task, v!),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: task.status,
                      decoration: const InputDecoration(labelText: 'Status'),
                      items: [
                        for (final status in TaskStatus.values)
                          DropdownMenuItem(
                            value: status,
                            child: StatusPriorityChip.status(status),
                          ),
                      ],
                      onChanged: (v) => _changeStatus(task, v!),
                    ),
                  ),
                ],
              ),
              const Divider(height: 32),
              Text(
                'Attachments',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              for (final uri in task.attachmentUris)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.attach_file),
                  title: Text(uri),
                  trailing: IconButton(
                    tooltip: 'Remove attachment',
                    icon: const Icon(Icons.close),
                    onPressed: () =>
                        _attachmentRepo.detach(task: task, uri: uri),
                  ),
                ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _attachPathController,
                      decoration: const InputDecoration(
                        labelText: 'File path to attach',
                        hintText: '/path/to/file.md',
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Attach file',
                    icon: const Icon(Icons.upload_file),
                    onPressed: () => _attachFile(task),
                  ),
                ],
              ),
              if (_attachError != null)
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _attachError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const Divider(height: 32),
              Text('Comments', style: Theme.of(context).textTheme.titleMedium),
              StreamBuilder<List<TaskComment>>(
                stream: _commentRepo.watchByTask(task.id),
                builder: (context, commentSnapshot) {
                  final comments =
                      commentSnapshot.data ?? const <TaskComment>[];
                  return Column(
                    children: [
                      for (final comment in comments)
                        ListTile(
                          dense: true,
                          title: Text(comment.body),
                          subtitle: Text(comment.author),
                        ),
                    ],
                  );
                },
              ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _commentController,
                      decoration: const InputDecoration(
                        labelText: 'Add a comment',
                      ),
                      onSubmitted: (_) => _addComment(task),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Add comment',
                    icon: const Icon(Icons.send),
                    onPressed: () => _addComment(task),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
