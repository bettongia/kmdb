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
import 'package:kmdb/kmdb.dart';

/// Dialog for editing an existing document's JSON body.
///
/// The editor is pre-populated with the formatted JSON of [document].
/// On save, [onSave] is called with the edited JSON string. The `_id`
/// field is always preserved by [CollectionProvider.updateDocument];
/// users may include or omit it in the editor without consequence.
///
/// [SchemaValidationException] is surfaced as a field-level error message
/// below the text area. Other errors propagate via [ErrorProvider].
class EditDocumentDialog extends StatefulWidget {
  /// The document to edit. Must contain an `_id` field.
  final Map<String, dynamic> document;

  /// Called with the edited JSON string when the user taps Save.
  final Future<void> Function(String json) onSave;

  const EditDocumentDialog({
    super.key,
    required this.document,
    required this.onSave,
  });

  @override
  State<EditDocumentDialog> createState() => _EditDocumentDialogState();
}

class _EditDocumentDialogState extends State<EditDocumentDialog> {
  late final TextEditingController _controller;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: const JsonEncoder.withIndent('  ').convert(widget.document),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final text = _controller.text.trim();

    // Validate JSON before calling the provider.
    try {
      final decoded = json.decode(text);
      if (decoded is! Map<String, dynamic>) {
        setState(() => _error = 'Input must be a JSON object.');
        return;
      }
    } on FormatException catch (e) {
      setState(() => _error = 'Invalid JSON: ${e.message}');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      await widget.onSave(text);
      if (mounted) Navigator.of(context).pop();
    } on SchemaValidationException catch (e) {
      setState(() => _error = e.toString());
    } catch (e) {
      // Other errors are surfaced via ErrorProvider; dismiss the dialog.
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        'Edit Document',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _controller,
              maxLines: 20,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                errorText: _error,
                isDense: true,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}
