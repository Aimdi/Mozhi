import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/image_translate/cubit/ocr_offer_cubit.dart';
import 'package:mozhi/image_translate/data/text_recognition_service.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/cubit/offline_models_state.dart';
import 'package:mozhi/offline/data/offline_model_error.dart';
import 'package:mozhi/offline/data/offline_model_file_picker.dart';
import 'package:mozhi/offline/view/offline_models_page.dart'
    show MeteredDownloadDialog, offlineOutcomeMessage;
import 'package:mozhi/platform/clipboard_service.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/view/widgets/delete_local_data.dart'
    show formatStoredSize;
import 'package:translation_repository/translation_repository.dart';

/// Shown instead of an error when on-device text recognition lacks the
/// data for the image's language ([missing]): "Download German text
/// recognition (1.5 MB)" (never downloaded without this tap; Wi-Fi only
/// asks first on a metered network), "Import from files" (no network, for
/// Offline only) and the file's link for a download by hand. Calls
/// [onInstalled] once the data is on the device, to recognise the image.
///
/// [store] (the "Download over Wi-Fi only" setting) defaults to the
/// [KeyValueStore] provided above, [picker] to the platform file picker.
class OcrLanguageOffer extends StatelessWidget {
  const new({
    required this.missing,
    required this.data,
    required this.onInstalled,
    this.store,
    this.picker,
    super.key,
  });

  final OcrDataMissingException missing;
  final TextRecognitionLanguageData data;
  final VoidCallback onInstalled;
  final KeyValueStore? store;
  final OfflineModelFilePicker? picker;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => OcrOfferCubit(
        data: data,
        language: missing.language,
        store:
            store ?? _maybeRead<KeyValueStore>(context) ?? PreferencesStore(),
        picker: picker ?? const OfflineModelFilePicker(),
      ),
      child: OcrLanguageOfferView(missing: missing, onInstalled: onInstalled),
    );
  }

  static T? _maybeRead<T>(BuildContext context) {
    try {
      return context.read<T>();
    } on ProviderNotFoundException {
      return null;
    }
  }
}

class OcrLanguageOfferView extends StatelessWidget {
  const new({required this.missing, required this.onInstalled, super.key});

  final OcrDataMissingException missing;
  final VoidCallback onInstalled;

  OfflineLanguage _language() => OfflineLanguage(
    code: missing.language.appCode,
    name: LanguageCatalog.nameOf(missing.language.appCode),
  );

  Future<void> _askMetered(BuildContext context) async {
    final cubit = context.read<OcrOfferCubit>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => MeteredDownloadDialog(
        language: _language(),
        size: missing.language.downloadSize,
      ),
    );
    if (confirmed ?? false) await cubit.download(overMeteredNetwork: true);
  }

  Future<void> _copyLink(BuildContext context, Uri url) async {
    final messenger = ScaffoldMessenger.of(context);
    final copied = context.l10n.commonCopied;
    await copyText(url.toString());
    // Android 13+ confirms copies itself.
    if (systemShowsCopyConfirmation) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(copied)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final state = context.watch<OcrOfferCubit>().state;
    final cubit = context.read<OcrOfferCubit>();
    final language = missing.language;
    final name = context.languageNameOf(language.appCode);
    final size = formatStoredSize(l10n, language.downloadSize);
    final offlineOnly = _offlineOnly(context);
    final url = language.url;
    final progress = state.progress;

    final download = state.status == OcrOfferStatus.downloading
        ? l10n.imageTranslateOcrDownloadingProgress(
            name,
            ((progress ?? 0) * 100).floor(),
          )
        : l10n.imageTranslateOcrDownload(name, size);
    final downloadButton = offlineOnly
        ? OutlinedButton.icon(
            key: const Key('image_translate_ocr_download'),
            onPressed: state.isBusy ? null : () => unawaited(cubit.download()),
            icon: const Icon(Icons.download_for_offline_outlined),
            label: Text(download),
          )
        : FilledButton.icon(
            key: const Key('image_translate_ocr_download'),
            onPressed: state.isBusy ? null : () => unawaited(cubit.download()),
            icon: const Icon(Icons.download_for_offline_outlined),
            label: Text(download),
          );
    final importLabel = state.status == OcrOfferStatus.importing
        ? l10n.offlineImporting
        : l10n.offlineImportAction;
    final importButton = offlineOnly
        ? FilledButton.icon(
            key: const Key('image_translate_ocr_import'),
            onPressed: state.isBusy
                ? null
                : () => unawaited(cubit.importFromFiles()),
            icon: const Icon(Icons.file_open_outlined),
            label: Text(importLabel),
          )
        : TextButton.icon(
            key: const Key('image_translate_ocr_import'),
            onPressed: state.isBusy
                ? null
                : () => unawaited(cubit.importFromFiles()),
            icon: const Icon(Icons.file_open_outlined),
            label: Text(importLabel),
          );
    final message = _message(l10n, state, name);

    return BlocListener<OcrOfferCubit, OcrOfferState>(
      listenWhen: (previous, current) =>
          previous.status != current.status || previous.error != current.error,
      listener: (context, state) {
        if (state.status == OcrOfferStatus.installed) {
          onInstalled();
        } else if (state.error?.kind == OfflineModelErrorKind.metered) {
          unawaited(_askMetered(context));
        }
      },
      child: DecoratedBox(
        key: const Key('image_translate_ocr_offer'),
        decoration: BoxDecoration(
          border: Border.all(color: palette.hairline),
          borderRadius: AppLook.of(context).cardRadius,
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 12,
                children: [
                  Icon(
                    Icons.document_scanner_outlined,
                    color: theme.colorScheme.primary,
                  ),
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        missing.guessed
                            ? l10n.imageTranslateOcrGuessTitle
                            : l10n.imageTranslateOcrMissingTitle(name),
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                missing.guessed
                    ? l10n.imageTranslateOcrGuessBody(name)
                    : l10n.imageTranslateOcrMissingBody(name),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: palette.secondaryText,
                ),
              ),
              if (offlineOnly) ...[
                const SizedBox(height: 8),
                Text(
                  l10n.imageTranslateOcrOfflineOnlyHint(language.fileName),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: palette.secondaryText,
                  ),
                ),
              ],
              if (state.status == OcrOfferStatus.downloading) ...[
                const SizedBox(height: 12),
                LinearProgressIndicator(
                  value: progress,
                  semanticsLabel: download,
                ),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (offlineOnly) importButton else downloadButton,
                  if (offlineOnly) downloadButton else importButton,
                  if (url != null)
                    TextButton.icon(
                      key: const Key('image_translate_ocr_copy_link'),
                      onPressed: () => unawaited(_copyLink(context, url)),
                      icon: const Icon(Icons.link),
                      label: Text(l10n.imageTranslateOcrCopyLink),
                    ),
                ],
              ),
              if (message != null) ...[
                const SizedBox(height: 8),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    message,
                    key: const Key('image_translate_ocr_message'),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Why the last download or import did not help, if it did not.
  String? _message(AppLocalizations l10n, OcrOfferState state, String name) {
    final error = state.error;
    if (error != null && error.kind != OfflineModelErrorKind.metered) {
      return offlineOutcomeMessage(
        l10n,
        OfflineModelOutcome(
          language: _language(),
          operation: OfflineModelOperation.download,
          succeeded: false,
          error: error,
        ),
      );
    }
    final report = state.importReport;
    if (report == null) return null;
    final file = missing.language.fileName;
    if (report.damaged.contains(missing.language.code)) {
      return l10n.imageTranslateOcrImportDamaged(file);
    }
    if (report.error != null || report.failed.isNotEmpty) {
      return l10n.offlineImportError;
    }
    return l10n.imageTranslateOcrImportNoMatch(file);
  }

  /// Whether the privacy mode is Offline only (import first).
  static bool _offlineOnly(BuildContext context) {
    try {
      return context.read<SettingsCubit>().state.privacyMode ==
          PrivacyMode.offlineOnly;
    } on ProviderNotFoundException {
      return false;
    }
  }
}
