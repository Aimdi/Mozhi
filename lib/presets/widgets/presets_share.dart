import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/platform/clipboard_service.dart';
import 'package:share_plus/share_plus.dart';

/// Signature of [PresetsShare.share].
typedef ShareTextFile = Future<void> Function(
  String text, {
  required String fileName,
  required String mimeType,
});

/// Shares exported presets and glossaries as files.
abstract final class PresetsShare {
  /// Replaceable in tests.
  @visibleForTesting
  static ShareTextFile share = _defaultShare;

  /// Restores the default implementation (for tests).
  @visibleForTesting
  static void reset() => share = _defaultShare;

  static Future<void> _defaultShare(
    String text, {
    required String fileName,
    required String mimeType,
  }) async {
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(
              utf8.encode(text),
              mimeType: mimeType,
              name: fileName,
            ),
          ],
          fileNameOverrides: [fileName],
          subject: fileName,
        ),
      );
    } on Object {
      // File sharing is unsupported on some platforms (e.g. Linux).
      await SharePlus.instance.share(ShareParams(text: text));
    }
  }
}

enum _ExportChoice { copy, share }

/// Bottom sheet offering to copy [build]'s text or share it as [fileName].
/// Shows a snackbar when copied or when [build] / sharing fails.
Future<void> showExportSheet(
  BuildContext context, {
  required String Function() build,
  required String fileName,
  required String mimeType,
}) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final choice = await showModalBottomSheet<_ExportChoice>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            key: const Key('presets_export_copy'),
            leading: const Icon(Icons.copy_outlined),
            title: Text(l10n.presetsCopyJson),
            onTap: () => Navigator.of(context).pop(_ExportChoice.copy),
          ),
          ListTile(
            key: const Key('presets_export_share'),
            leading: const Icon(Icons.share_outlined),
            title: Text(l10n.presetsShareFile),
            onTap: () => Navigator.of(context).pop(_ExportChoice.share),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (choice == null) return;
  await exportText(
    messenger,
    l10n,
    build: build,
    copy: choice == _ExportChoice.copy,
    fileName: fileName,
    mimeType: mimeType,
  );
}

/// Copies or shares [build]'s text, reporting the outcome on [messenger].
Future<void> exportText(
  ScaffoldMessengerState? messenger,
  AppLocalizations l10n, {
  required String Function() build,
  required bool copy,
  required String fileName,
  required String mimeType,
}) async {
  try {
    final text = build();
    if (copy) {
      await copyText(text);
      // Android 13+ confirms copies itself.
      if (!systemShowsCopyConfirmation) {
        messenger?.showSnackBar(SnackBar(content: Text(l10n.commonCopied)));
      }
    } else {
      await PresetsShare.share(text, fileName: fileName, mimeType: mimeType);
    }
  } on Object {
    messenger?.showSnackBar(SnackBar(content: Text(l10n.presetsExportFailed)));
  }
}
