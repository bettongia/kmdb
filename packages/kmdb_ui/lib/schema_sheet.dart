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

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_json_view/flutter_json_view.dart';
import 'package:provider/provider.dart';

import 'app_provider.dart';

/// Shows the schema management bottom sheet for [collectionName].
void showSchemaSheet(BuildContext context, String collectionName) {
  final appProvider = context.read<AppProvider>();
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => ChangeNotifierProvider.value(
      value: appProvider,
      child: _SchemaSheet(collectionName: collectionName),
    ),
  );
}

class _SchemaSheet extends StatelessWidget {
  const _SchemaSheet({required this.collectionName});

  final String collectionName;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => _SchemaSheetContent(
        collectionName: collectionName,
        scrollController: scrollController,
      ),
    );
  }
}

class _SchemaSheetContent extends StatelessWidget {
  const _SchemaSheetContent({
    required this.collectionName,
    required this.scrollController,
  });

  final String collectionName;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    final appProvider = context.watch<AppProvider>();
    final schema = appProvider.schemaForCollection(collectionName);

    return Column(
      children: [
        // Handle bar.
        Center(
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 8),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade400,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),

        // Header row.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
          child: Row(
            children: [
              const Icon(Icons.rule_outlined, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Schema — $collectionName',
                  style: Theme.of(context).textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton.icon(
                icon: const Icon(Icons.edit_outlined, size: 16),
                label: Text(schema == null ? 'Set Schema' : 'Replace'),
                onPressed: () => _showSetSchemaDialog(context, appProvider),
              ),
              if (schema != null)
                TextButton.icon(
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: const Text('Remove'),
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  ),
                  onPressed: () => _confirmRemove(context, appProvider),
                ),
            ],
          ),
        ),

        const Divider(height: 1),

        // Body.
        Expanded(
          child: schema == null
              ? _buildEmpty(context)
              : _buildSchemaView(
                  context,
                  appProvider,
                  schema,
                  scrollController,
                ),
        ),
      ],
    );
  }

  Widget _buildEmpty(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.rule_folder_outlined,
            size: 48,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            'No schema registered for "$collectionName".',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Tap "Set Schema" to register a JSON Schema.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildSchemaView(
    BuildContext context,
    AppProvider appProvider,
    Map<String, dynamic> schema,
    ScrollController scrollController,
  ) {
    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: JsonView.map(
              schema,
              theme: const JsonViewTheme(
                viewType: JsonViewType.collapsible,
                backgroundColor: Colors.transparent,
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.tonal(
          onPressed: () => _showValidateDialog(context, appProvider),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.check_circle_outline, size: 16),
              SizedBox(width: 8),
              Text('Validate a Document'),
            ],
          ),
        ),
      ],
    );
  }

  // ── Dialogs ──────────────────────────────────────────────────────────────────

  Future<void> _showSetSchemaDialog(
    BuildContext context,
    AppProvider appProvider,
  ) async {
    final controller = TextEditingController(
      text: appProvider.schemaForCollection(collectionName) != null
          ? const JsonEncoder.withIndent(
              '  ',
            ).convert(appProvider.schemaForCollection(collectionName))
          : '',
    );
    String? errorText;

    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text('Set Schema — $collectionName'),
          content: SizedBox(
            width: 500,
            child: TextField(
              controller: controller,
              autofocus: true,
              maxLines: 14,
              decoration: InputDecoration(
                hintText: '{"required": ["name"], "properties": {...}}',
                border: const OutlineInputBorder(),
                errorText: errorText,
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                final err = await appProvider.runBusy(
                  'Registering schema…',
                  () => appProvider.registerSchema(
                    collectionName,
                    controller.text.trim(),
                  ),
                );
                if (err != null) {
                  setState(() => errorText = err);
                } else if (context.mounted) {
                  Navigator.pop(context);
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
  }

  Future<void> _confirmRemove(
    BuildContext context,
    AppProvider appProvider,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Remove Schema'),
        content: Text(
          'Remove the JSON schema for "$collectionName"?\n\n'
          'Existing documents will not be affected, but future writes '
          'will no longer be validated.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      await appProvider.runBusy(
        'Removing schema…',
        () => appProvider.deregisterSchema(collectionName),
      );
    }
  }

  Future<void> _showValidateDialog(
    BuildContext context,
    AppProvider appProvider,
  ) async {
    final controller = TextEditingController();
    String? result;
    bool? isValid;

    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Validate Document'),
          content: SizedBox(
            width: 500,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  maxLines: 10,
                  decoration: const InputDecoration(
                    hintText: '{"name": "Alice", ...}',
                    border: OutlineInputBorder(),
                    labelText: 'Document JSON',
                  ),
                ),
                if (result != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: isValid == true
                          ? Colors.green.shade50
                          : Colors.red.shade50,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: isValid == true ? Colors.green : Colors.red,
                      ),
                    ),
                    child: Text(
                      result!,
                      style: TextStyle(
                        color: isValid == true
                            ? Colors.green.shade800
                            : Colors.red.shade800,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
            FilledButton(
              onPressed: () {
                final err = appProvider.validateDocumentJson(
                  collectionName,
                  controller.text.trim(),
                );
                setState(() {
                  isValid = err == null;
                  result = err ?? 'Document is valid.';
                });
              },
              child: const Text('Validate'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
  }
}
