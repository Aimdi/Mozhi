import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/cubit/offline_models_state.dart';
import 'package:mozhi/platform/clipboard_service.dart';
import 'package:mozhi/settings/models/model_source.dart';
import 'package:mozhi/settings/view/widgets/delete_local_data.dart'
    show formatStoredSize;
import 'package:tesseract_ocr/tesseract_ocr.dart' show tessdataMirrorFolder;

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
/// device) and import, with a copyable download link: where the app
/// downloads from (a mirror, when that is the model source), with the
/// publisher's link as the fallback.
class OcrManualFileSheet extends StatefulWidget {
  /// [source] is the model source (default: [ModelSource.current], the
  /// settings').
  const new({
    required this.language,
    required this.data,
    this.source,
    super.key,
  });

  final OfflineLanguage language;
  final OcrLanguage data;
  final ModelSource? source;

  /// Where the app downloads [data] from with [source]: on its mirror,
  /// `<mirror>/tesseract/<file>` (the layout of `tessdataMirrorUrl`), or
  /// null for the publisher's link ([OcrLanguage.url]).
  Uri? get mirrorUrl => (source ?? ModelSource.current).mirror()?.resolveUri(
    Uri(pathSegments: [tessdataMirrorFolder, data.fileName]),
  );

  @override
  State<OcrManualFileSheet> createState() => _OcrManualFileSheetState();
}

class _OcrManualFileSheetState extends State<OcrManualFileSheet> {
  /// The link copied last.
  String? _copied;

  Future<void> _copy(String url) async {
    await copyText(url);
    if (mounted) setState(() => _copied = url);
  }

  Widget _copyButton(
    String url, {
    required String tooltip,
    required IconData icon,
  }) {
    final copied = _copied == url;
    return IconButton(
      tooltip: copied ? context.l10n.commonCopied : tooltip,
      icon: Icon(copied ? Icons.check : icon),
      onPressed: () => unawaited(_copy(url)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final secondary = AppPalette.of(context).secondaryText;
    final name = widget.language.displayNameIn(l10n.localeName);
    final fileName = widget.data.fileName;
    final publisher = widget.data.url?.toString();
    final mirror = widget.mirrorUrl;
    final link = mirror?.toString() ?? publisher;
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
            l10n.offlineOcrManualBody(name),
            style: theme.textTheme.bodyMedium?.copyWith(color: secondary),
          ),
        ),
        if (mirror != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              l10n.offlineManualMirrorNote(mirror.host),
              style: theme.textTheme.bodyMedium?.copyWith(color: secondary),
            ),
          ),
        ListTile(
          key: const Key('offline_ocr_manual_file'),
          contentPadding: const EdgeInsetsDirectional.only(start: 24, end: 12),
          title: Text(
            fileName,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFamily: 'monospace',
            ),
          ),
          subtitle: Text(
            formatStoredSize(l10n, widget.data.downloadSize),
            style: TextStyle(color: secondary),
          ),
          trailing: link == null
              ? null
              : _copyButton(
                  link,
                  tooltip: l10n.offlineManualCopyLink(fileName),
                  icon: Icons.link,
                ),
        ),
        if (mirror != null && publisher != null)
          ListTile(
            key: const Key('offline_ocr_manual_publisher'),
            dense: true,
            contentPadding: const EdgeInsetsDirectional.only(
              start: 40,
              end: 12,
            ),
            title: Text(
              l10n.offlineManualPublisherLink,
              style: TextStyle(color: secondary),
            ),
            trailing: _copyButton(
              publisher,
              tooltip: l10n.offlineManualCopyPublisherLink(fileName),
              icon: Icons.public,
            ),
          ),
      ],
    );
  }
}
