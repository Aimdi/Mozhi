import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/cubit/offline_models_state.dart';
import 'package:mozhi/platform/clipboard_service.dart';
import 'package:mozhi/settings/view/widgets/delete_local_data.dart'
    show formatStoredSize;

/// Opens [OcrManualFileSheet] for [language].
Future<void> showOcrManualFileSheet(
  BuildContext context, {
  required OfflineLanguage language,
  required OcrLanguage data,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (_) => OcrManualFileSheet(language: language, data: data),
);

/// The text recognition file of [language] to download by hand (on another
/// device) and import, with a copyable download link.
class OcrManualFileSheet extends StatefulWidget {
  const new({required this.language, required this.data, super.key});

  final OfflineLanguage language;
  final OcrLanguage data;

  @override
  State<OcrManualFileSheet> createState() => _OcrManualFileSheetState();
}

class _OcrManualFileSheetState extends State<OcrManualFileSheet> {
  var _copied = false;

  Future<void> _copy(String url) async {
    await copyText(url);
    if (mounted) setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final secondary = AppPalette.of(context).secondaryText;
    final name = widget.language.name;
    final url = widget.data.url;
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
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
          child: Text(
            l10n.offlineOcrManualBody(name),
            style: theme.textTheme.bodyMedium?.copyWith(color: secondary),
          ),
        ),
        ListTile(
          key: const Key('offline_ocr_manual_file'),
          contentPadding: const EdgeInsetsDirectional.only(start: 24, end: 12),
          title: Text(
            widget.data.fileName,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFamily: 'monospace',
            ),
          ),
          subtitle: Text(
            formatStoredSize(l10n, widget.data.downloadSize),
            style: TextStyle(color: secondary),
          ),
          trailing: url == null
              ? null
              : IconButton(
                  tooltip: _copied
                      ? l10n.commonCopied
                      : l10n.offlineManualCopyLink(widget.data.fileName),
                  icon: Icon(_copied ? Icons.check : Icons.link),
                  onPressed: () => unawaited(_copy(url.toString())),
                ),
        ),
      ],
    );
  }
}
