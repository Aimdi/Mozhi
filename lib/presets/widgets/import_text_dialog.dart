import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/privacy/ime_learning.dart';
import 'package:mozhi/l10n/l10n.dart';

/// Shows [ImportTextDialog]; completes with [onImport]'s result, or `null`
/// when cancelled.
Future<T?> showImportTextDialog<T>(
  BuildContext context, {
  required String title,
  required String hint,
  required String invalidMessage,
  required Future<T> Function(String text) onImport,
  String? help,
}) => showDialog<T>(
  context: context,
  builder: (_) => ImportTextDialog<T>(
    title: title,
    hint: hint,
    help: help,
    invalidMessage: invalidMessage,
    onImport: onImport,
  ),
);

/// Paste text (JSON, CSV, ...) and hand it to [onImport]. Any error thrown by
/// [onImport] shows [invalidMessage]; on success the dialog pops the result.
class ImportTextDialog<T> extends StatefulWidget {
  const new({
    required this.title,
    required this.hint,
    required this.invalidMessage,
    required this.onImport,
    this.help,
    super.key,
  });

  final String title;
  final String hint;
  final String? help;
  final String invalidMessage;
  final Future<T> Function(String text) onImport;

  @override
  State<ImportTextDialog<T>> createState() => _ImportTextDialogState<T>();
}

class _ImportTextDialogState<T> extends State<ImportTextDialog<T>> {
  final _controller = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || !mounted) return;
    setState(() {
      _controller.text = text;
      _error = null;
    });
  }

  Future<void> _import() async {
    final text = _controller.text;
    if (text.trim().isEmpty) {
      setState(() => _error = widget.invalidMessage);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.onImport(text);
      if (mounted) Navigator.of(context).pop(result);
    } on Object {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = widget.invalidMessage;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.title),
      scrollable: true,
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.help case final help?) ...[
              Text(
                help,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              key: const Key('presets_import_field'),
              controller: _controller,
              enableIMEPersonalizedLearning: imeLearningAllowed(context),
              minLines: 4,
              maxLines: 10,
              keyboardType: TextInputType.multiline,
              style: const TextStyle(fontFamily: 'monospace'),
              decoration: InputDecoration(
                hintText: widget.hint,
                errorText: _error,
                errorMaxLines: 3,
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: _busy ? null : _paste,
                icon: const Icon(Icons.content_paste),
                label: Text(l10n.presetsPaste),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          key: const Key('presets_import_submit'),
          onPressed: _busy ? null : _import,
          child: Text(l10n.presetsImportAction),
        ),
      ],
    );
  }
}
