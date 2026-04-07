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

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

class NewDatabaseDialog extends StatefulWidget {
  const NewDatabaseDialog({super.key});

  @override
  State<NewDatabaseDialog> createState() => _NewDatabaseDialogState();
}

class _NewDatabaseDialogState extends State<NewDatabaseDialog> {
  String? _parentPath;
  final _nameController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  String? _collisionError;
  bool _canCreate = false;

  @override
  void initState() {
    super.initState();
    _nameController.addListener(_validate);
  }

  void _validate() {
    final name = _nameController.text.trim();
    String? newCollisionError;
    bool canCreate = true;

    if (_parentPath == null || name.isEmpty) {
      canCreate = false;
    } else {
      final fullPath = p.join(_parentPath!, name);
      if (Directory(fullPath).existsSync() || File(fullPath).existsSync()) {
        newCollisionError = 'A folder or file with this name already exists.';
        canCreate = false;
      }
    }

    if (newCollisionError != _collisionError || canCreate != _canCreate) {
      setState(() {
        _collisionError = newCollisionError;
        _canCreate = canCreate;
      });
    }
  }

  Future<void> _pickParentFolder() async {
    final path = await FilePicker.getDirectoryPath();
    if (path != null) {
      setState(() {
        _parentPath = path;
      });
      _validate();
    }
  }

  void _onCreate() {
    if (!_formKey.currentState!.validate()) return;
    if (_parentPath == null) return;
    if (_collisionError != null) return;

    final name = _nameController.text.trim();
    final fullPath = p.join(_parentPath!, name);

    Navigator.of(context).pop(fullPath);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New Database'),
      content: SizedBox(
        width: 400,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Select a parent directory and provide a name for your new KMDB database.',
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'PARENT DIRECTORY',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: Colors.blueGrey,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _parentPath ?? 'Not selected',
                          style: TextStyle(
                            fontSize: 12,
                            color: _parentPath == null ? Colors.grey : null,
                            fontStyle: _parentPath == null
                                ? FontStyle.italic
                                : null,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: _pickParentFolder,
                    icon: const Icon(Icons.folder_open, size: 16),
                    label: const Text('Browse'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _nameController,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'DATABASE NAME',
                  labelStyle: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                  hintText: 'e.g. mydb',
                  isDense: true,
                  border: const OutlineInputBorder(),
                  errorText: _collisionError,
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Please enter a name';
                  }
                  if (RegExp(r'[<>:"/\\|?*]').hasMatch(value)) {
                    return 'Invalid characters in name';
                  }
                  return null;
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _canCreate ? _onCreate : null,
          child: const Text('Create'),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _nameController.removeListener(_validate);
    _nameController.dispose();
    super.dispose();
  }
}
