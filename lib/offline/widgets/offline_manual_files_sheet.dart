import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/cubit/offline_models_state.dart';
import 'package:mozhi/offline/data/offline_model_import.dart';
import 'package:mozhi/offline/widgets/offline_import_summary.dart';
import 'package:mozhi/platform/clipboard_service.dart';
import 'package:mozhi/settings/view/widgets/delete_local_data.dart'
    show formatStoredSize;

/// Opens [OfflineManualFilesSheet] for [language].
Future<void> showOfflineManualFilesSheet(
  BuildContext context, {
  required OfflineLanguage language,
  required List<OfflineManualDirection> directions,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (_) =>
      OfflineManualFilesSheet(language: language, directions: directions),
);

/// The model files of [language] to download by hand (on another device)
/// and import, with copyable download links: where the app downloads from
/// (a mirror, when that is the model source, see
/// [OfflineModelFile.mirrorUrl]), with the publisher's link as the
/// fallback.
class OfflineManualFilesSheet extends StatefulWidget {
  const new({required this.language, required this.directions, super.key});

  final OfflineLanguage language;
  final List<OfflineManualDirection> directions;

  @override
  State<OfflineManualFilesSheet> createState() =>
      _OfflineManualFilesSheetState();
}

class _OfflineManualFilesSheetState extends State<OfflineManualFilesSheet> {
  /// What was copied last (a link, or every link), shown as done.
  String? _copied;

  Future<void> _copy(String text) async {
    await copyText(text);
    if (mounted) setState(() => _copied = text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final secondary = AppPalette.of(context).secondaryText;
    final name = widget.language.displayNameIn(l10n.localeName);
    final files = [
      for (final direction in widget.directions) ...direction.files,
    ];
    final all = [for (final file in files) file.preferredUrl].join('\n');
    final allCopied = _copied == all;
    final mirror = files.map((file) => file.mirrorUrl).nonNulls.firstOrNull;
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 24),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Semantics(
            header: true,
            child: Text(
              l10n.offlineManualTitle(name),
              style: theme.textTheme.titleLarge,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
          child: Text(
            // The web app imports into the browser, not to a phone.
            kIsWeb
                ? l10n.offlineManualBodyWeb(name)
                : l10n.offlineManualBody(name),
            style: theme.textTheme.bodyMedium?.copyWith(color: secondary),
          ),
        ),
        if (mirror != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              l10n.offlineManualMirrorNote(Uri.parse(mirror).host),
              style: theme.textTheme.bodyMedium?.copyWith(color: secondary),
            ),
          ),
        for (final direction in widget.directions) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 4),
            child: Text(
              offlineDirectionLabel(l10n, direction.source, direction.target),
              style: theme.textTheme.titleSmall,
            ),
          ),
          for (final file in direction.files) ..._fileTiles(l10n, file),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
          child: FilledButton.tonalIcon(
            key: const Key('offline_manual_copy_all'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            onPressed: () => unawaited(_copy(all)),
            icon: Icon(allCopied ? Icons.check : Icons.copy_all),
            label: Text(
              allCopied ? l10n.commonCopied : l10n.offlineManualCopyAll,
            ),
          ),
        ),
      ],
    );
  }

  /// The tile of [file] (its preferred link), and with a mirror one for
  /// the publisher's link.
  List<Widget> _fileTiles(AppLocalizations l10n, OfflineModelFile file) {
    final secondary = AppPalette.of(context).secondaryText;
    final link = file.preferredUrl;
    return [
      ListTile(
        contentPadding: const EdgeInsetsDirectional.only(start: 24, end: 12),
        title: Text(
          file.name,
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(fontFamily: 'monospace'),
        ),
        subtitle: Text(
          formatStoredSize(l10n, file.size),
          style: TextStyle(color: secondary),
        ),
        trailing: _copyButton(
          link,
          tooltip: l10n.offlineManualCopyLink(file.name),
          icon: Icons.link,
        ),
      ),
      if (file.mirrorUrl != null)
        ListTile(
          dense: true,
          contentPadding: const EdgeInsetsDirectional.only(start: 40, end: 12),
          title: Text(
            l10n.offlineManualPublisherLink,
            style: TextStyle(color: secondary),
          ),
          trailing: _copyButton(
            file.url,
            tooltip: l10n.offlineManualCopyPublisherLink(file.name),
            icon: Icons.public,
          ),
        ),
    ];
  }

  Widget _copyButton(
    String text, {
    required String tooltip,
    required IconData icon,
  }) {
    final copied = _copied == text;
    return IconButton(
      tooltip: copied ? context.l10n.commonCopied : tooltip,
      icon: Icon(copied ? Icons.check : icon),
      onPressed: () => unawaited(_copy(text)),
    );
  }
}
