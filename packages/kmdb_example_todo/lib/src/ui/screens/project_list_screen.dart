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
import '../../repositories/project_repository.dart';
import 'search_screen.dart';
import 'sync_settings_screen.dart';
import 'task_list_screen.dart';

/// Screen 2 of 6 — "Project list".
///
/// Demonstrates `ProjectRepository.watchAll()` (reactive `KmdbQuery.watch()`,
/// spec §14) and `insert()` via a create dialog.
class ProjectListScreen extends StatefulWidget {
  /// Creates the [ProjectListScreen] for [db].
  const ProjectListScreen({required this.db, super.key});

  /// The open database, threaded through every screen in this app.
  final KmdbDatabase db;

  @override
  State<ProjectListScreen> createState() => _ProjectListScreenState();
}

class _ProjectListScreenState extends State<ProjectListScreen> {
  late final ProjectRepository _repo = ProjectRepository(widget.db);

  Future<void> _createProject() async {
    final nameController = TextEditingController();
    final descriptionController = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New project'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            TextField(
              controller: descriptionController,
              decoration: const InputDecoration(labelText: 'Description'),
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
    );

    if (result != true || nameController.text.trim().isEmpty) return;
    await _repo.create(
      Project(
        id: '',
        name: nameController.text.trim(),
        description: descriptionController.text.trim(),
        createdAt: DateTime.now(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Projects'),
        actions: [
          IconButton(
            tooltip: 'Search',
            icon: const Icon(Icons.search),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => SearchScreen(db: widget.db)),
            ),
          ),
          IconButton(
            tooltip: 'Sync and settings',
            icon: const Icon(Icons.sync),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SyncSettingsScreen(db: widget.db),
              ),
            ),
          ),
        ],
      ),
      body: StreamBuilder<List<Project>>(
        stream: _repo.watchAll(),
        builder: (context, snapshot) {
          final projects = snapshot.data ?? const <Project>[];
          if (snapshot.connectionState == ConnectionState.waiting &&
              projects.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }
          if (projects.isEmpty) {
            return const Center(
              child: Text('No projects yet. Tap + to create one.'),
            );
          }
          return ListView.builder(
            itemCount: projects.length,
            itemBuilder: (context, index) {
              final project = projects[index];
              return ListTile(
                title: Text(project.name),
                subtitle: project.description.isEmpty
                    ? null
                    : Text(project.description),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        TaskListScreen(db: widget.db, project: project),
                  ),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'New project',
        onPressed: _createProject,
        child: const Icon(Icons.add),
      ),
    );
  }
}
