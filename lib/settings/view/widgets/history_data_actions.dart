import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:share_plus/share_plus.dart';

/// Shares an exported history JSON document.
abstract final class HistoryShare {
  /// Replaceable in tests.
  @visibleForTesting
  static Future<void> Function(String json) share = _defaultShare;

  static const fileName = 'mozhi-history.json';

  static Future<void> _defaultShare(String json) async {
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(
              utf8.encode(json),
              mimeType: 'application/json',
              name: fileName,
            ),
          ],
          fileNameOverrides: const [fileName],
          subject: fileName,
        ),
      );
    } on Object {
      // File sharing is unsupported on some platforms (e.g. Linux).
      await SharePlus.instance.share(ShareParams(text: json));
    }
  }
}

enum _ExportChoice { copy, share }

/// Lets the user copy the history JSON to the clipboard or share it.
Future<void> showExportHistorySheet(BuildContext context) async {
  final l10n = context.l10n;
  final cubit = context.read<HistoryCubit>();
  final messenger = ScaffoldMessenger.maybeOf(context);
  final choice = await showModalBottomSheet<_ExportChoice>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.copy_outlined),
            title: Text(l10n.settingsExportCopy),
            onTap: () => Navigator.of(context).pop(_ExportChoice.copy),
          ),
          ListTile(
            leading: const Icon(Icons.share_outlined),
            title: Text(l10n.settingsExportShare),
            onTap: () => Navigator.of(context).pop(_ExportChoice.share),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (choice == null) return;
  try {
    final json = await cubit.exportJson();
    switch (choice) {
      case _ExportChoice.copy:
        await Clipboard.setData(ClipboardData(text: json));
        messenger?.showSnackBar(
          SnackBar(content: Text(l10n.settingsExportCopied)),
        );
      case _ExportChoice.share:
        await HistoryShare.share(json);
    }
  } on Object {
    messenger?.showSnackBar(SnackBar(content: Text(l10n.settingsExportFailed)));
  }
}

/// Shows the paste-JSON import dialog; reports success with a snackbar.
Future<void> showImportHistoryDialog(BuildContext context) async {
  final cubit = context.read<HistoryCubit>();
  final messenger = ScaffoldMessenger.maybeOf(context);
  final doneMessage = context.l10n.settingsImportDone;
  final imported = await showDialog<bool>(
    context: context,
    builder: (_) =>
        BlocProvider.value(value: cubit, child: const ImportHistoryDialog()),
  );
  if (imported ?? false) {
    messenger?.showSnackBar(SnackBar(content: Text(doneMessage)));
  }
}

/// Paste exported JSON and import it into [HistoryCubit]. Pops `true` on
/// success.
class ImportHistoryDialog extends StatefulWidget {
  const new({super.key});

  @override
  State<ImportHistoryDialog> createState() => _ImportHistoryDialogState();
}

class _ImportHistoryDialogState extends State<ImportHistoryDialog> {
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
    final text = _controller.text.trim();
    final invalid = context.l10n.settingsImportInvalid;
    if (text.isEmpty) {
      setState(() => _error = invalid);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<HistoryCubit>().importJson(text);
      if (mounted) Navigator.of(context).pop(true);
    } on Object {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = invalid;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.settingsImportHistory),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _controller,
            minLines: 4,
            maxLines: 8,
            keyboardType: TextInputType.multiline,
            style: const TextStyle(fontFamily: 'monospace'),
            decoration: InputDecoration(
              labelText: l10n.settingsImportLabel,
              hintText: l10n.settingsImportHint,
              alignLabelWithHint: true,
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
              label: Text(l10n.settingsImportPaste),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: _busy ? null : _import,
          child: Text(l10n.settingsImportAction),
        ),
      ],
    );
  }
}
