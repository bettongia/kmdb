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
import 'package:provider/provider.dart';
import 'app_provider.dart';

/// Dialog for creating a new collection in the open database.
class NewCollectionDialog extends StatefulWidget {
  const NewCollectionDialog({super.key});

  @override
  State<NewCollectionDialog> createState() => _NewCollectionDialogState();
}

class _NewCollectionDialogState extends State<NewCollectionDialog> {
  final _nameController = TextEditingController();
  String? _errorText;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _validate(String value, List<String> existing) {
    setState(() {
      if (value.isEmpty) {
        _errorText = null;
      } else if (existing.contains(value)) {
        _errorText = 'Collection already exists';
      } else {
        _errorText = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final existing = provider.collections;

    return AlertDialog(
      title: const Text('Add Collection'),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'COLLECTION NAME',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: Colors.blueGrey,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _nameController,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'e.g. users, tasks',
                hintStyle: const TextStyle(fontSize: 13),
                errorText: _errorText,
                errorStyle: const TextStyle(color: Colors.orange),
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
              ),
              onChanged: (v) => _validate(v, existing),
              onSubmitted: (_) {
                if (_nameController.text.isNotEmpty) {
                  _handleCreate(context, provider);
                }
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _nameController.text.isEmpty
              ? null
              : () => _handleCreate(context, provider),
          child: const Text('Create'),
        ),
      ],
    );
  }

  Future<void> _handleCreate(BuildContext context, AppProvider provider) async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;

    await provider.createCollection(name);
    if (context.mounted) {
      Navigator.pop(context);
    }
  }
}
