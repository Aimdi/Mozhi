import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/cubit/offline_models_cubit.dart';
import 'package:mozhi/offline/data/bergamot_model_details.dart'
    show offlineModelDetailsOf;
import 'package:mozhi/offline/data/offline_model_details.dart';
import 'package:mozhi/offline/view/offline_models_page.dart'
    show MeteredDownloadDialog, offlineOutcomeMessage;
import 'package:mozhi/offline/widgets/offline_language_tile.dart'
    show OfflineCancelDownloadButton;
import 'package:mozhi/settings/view/widgets/delete_local_data.dart'
    show formatStoredSize;
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

/// A language to download for translating on this device.
typedef OfflineDownload = ({String code, String name, int? bytes});

/// The label of a button that downloads [downloads]: "Download German
/// (25 MB)", "Download German, Japanese (52 MB)", or without the size when
/// it is unknown.
String offlineDownloadLabel(
  AppLocalizations l10n,
  List<OfflineDownload> downloads,
) {
  final names = [for (final download in downloads) download.name].join(', ');
  final sizes = [for (final download in downloads) download.bytes];
  if (sizes.isEmpty || sizes.any((size) => size == null || size <= 0)) {
    return l10n.translateOfflineDownloadLanguage(names);
  }
  final total = sizes.fold<int>(0, (sum, size) => sum + size!);
  return l10n.translateOfflineDownload(names, formatStoredSize(l10n, total));
}

/// Translates the translate screen's text on the device once its languages
/// are there: the [TranslateCubit] above [context] translates again when
/// the on-device engine is selected already (Offline first tried it
/// first), else it switches to it (`TranslateCubit.selectEngine`, which
/// translates). Nothing is sent: the on-device engine translates on the
/// device. Does nothing without a translate screen or an on-device engine.
void translateOnDevice(BuildContext context) {
  final TranslateCubit cubit;
  try {
    cubit = context.read<TranslateCubit>();
  } on ProviderNotFoundException {
    return;
  }
  final offline = cubit.state.engines.where((e) => e.isOffline).firstOrNull;
  if (offline == null) return;
  unawaited(
    cubit.state.engine?.id == offline.id
        ? cubit.translate()
        : cubit.selectEngine(offline),
  );
}

/// "Download French (49.6 MB)" that downloads [downloads] right here, in
/// turn, through the same [OfflineModelsCubit] as Settings › Offline
/// languages (its free space and checksum checks, and "Download over Wi-Fi
/// only": on a metered network it asks first with the same
/// [MeteredDownloadDialog]). While it runs it shows the language and the
/// progress (a live region); a failure is said in place, and the button
/// tries again. Once every language is there, [onReady] runs (default:
/// [translateOnDevice], so the pending text is translated on the device).
/// "Manage languages" opens the offline languages page.
///
/// The download only starts when the user taps the button. While it runs,
/// Cancel (when the engine can stop downloads,
/// [OfflineModelsState.canCancel]) stops it quietly, with the remaining
/// languages: the button comes back, without an error, and the next
/// download resumes what was received. Otherwise it goes on in the
/// background when the card goes away (the models are then there for the
/// next translation); an interrupted download resumes next time.
///
/// [translator] defaults to the [OfflineTranslator] provided above,
/// [store] (where "Wi-Fi only" is remembered) to the [KeyValueStore] above,
/// else the platform preferences.
class OfflineDownloadAction extends StatefulWidget {
  const new({
    required this.downloads,
    this.translator,
    this.store,
    this.onReady,
    this.onManaged,
    this.details,
    super.key,
  });

  /// Sizes and progress of the downloads; defaults to those of
  /// [translator] (`offlineModelDetailsOf`).
  final OfflineModelDetails? details;

  final List<OfflineDownload> downloads;

  /// Runs when the user comes back from the offline languages page
  /// ("Manage languages"), where they may have downloaded them.
  final VoidCallback? onManaged;
  final OfflineTranslator? translator;
  final KeyValueStore? store;

  /// Runs once every language of [downloads] is on the device.
  final VoidCallback? onReady;

  @override
  State<OfflineDownloadAction> createState() => _OfflineDownloadActionState();
}

class _OfflineDownloadActionState extends State<OfflineDownloadAction> {
  OfflineModelsCubit? _models;
  StreamSubscription<OfflineModelsState>? _changes;

  /// The language downloading now (null when idle).
  OfflineDownload? _current;
  double? _progress;
  String? _error;

  /// The user cancelled the running download.
  bool _cancelled = false;

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    unawaited(_models?.close());
    super.dispose();
  }

  T? _maybeRead<T>() {
    try {
      return context.read<T>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  OfflineModelsCubit? _cubit() {
    if (_models case final models?) return models;
    final translator = widget.translator ?? _maybeRead<OfflineTranslator>();
    if (translator == null || !translator.isAvailable) return null;
    final models = OfflineModelsCubit(
      translator: translator,
      store: widget.store ?? _maybeRead<KeyValueStore>() ?? PreferencesStore(),
      details: widget.details ?? offlineModelDetailsOf(translator),
    );
    _changes = models.stream.listen((state) {
      final code = _current?.code;
      if (!mounted || code == null) return;
      final progress = state.progress[code];
      if (progress != _progress) setState(() => _progress = progress);
    });
    return _models = models;
  }

  Future<void> _download() async {
    final models = _cubit();
    if (models == null || _current != null) return;
    setState(() {
      _error = null;
      _cancelled = false;
    });
    if (models.state.status != OfflineModelsStatus.ready) await models.load();
    for (final download in widget.downloads) {
      if (!mounted) return;
      if (models.state.isDownloaded(download.code)) continue;
      setState(() {
        _current = download;
        _progress = null;
      });
      if (!await _downloadOne(models, download)) {
        if (mounted) setState(() => _current = null);
        return;
      }
    }
    if (!mounted) return;
    setState(() => _current = null);
    (widget.onReady ?? () => translateOnDevice(context))();
  }

  /// Downloads [download] (asking first on a metered network); whether it
  /// is on the device now.
  Future<bool> _downloadOne(
    OfflineModelsCubit models,
    OfflineDownload download,
  ) async {
    await models.download(download.code);
    if (_cancelled) return false;
    var outcome = models.state.outcome;
    if (outcome != null && outcome.needsMeteredConsent && mounted) {
      final anyway = await showDialog<bool>(
        context: context,
        builder: (_) => MeteredDownloadDialog(
          language: outcome!.language,
          size: models.state.downloadSizeOf(download.code) ?? download.bytes,
        ),
      );
      if (!(anyway ?? false)) return false;
      await models.download(download.code, overMeteredNetwork: true);
      if (_cancelled) return false;
      outcome = models.state.outcome;
    }
    if (outcome == null || outcome.succeeded) return true;
    if (mounted) {
      setState(() => _error = offlineOutcomeMessage(context.l10n, outcome!));
    }
    return false;
  }

  /// Stops the running download (and the languages after it), quietly.
  Future<void> _cancel() async {
    final models = _models;
    final current = _current;
    if (models == null || current == null || _cancelled) return;
    setState(() => _cancelled = true);
    await models.cancelDownload(current.code);
  }

  Future<void> _manage() async {
    await GoRouter.of(context).push<void>(AppRoutes.offline);
    if (mounted) widget.onManaged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final current = _current;
    final error = _error;
    final manage = TextButton(
      key: const Key('translate_offline_manage'),
      style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
      onPressed: () => unawaited(_manage()),
      child: Text(l10n.translateOfflineManageLanguages),
    );
    if (current != null) {
      final progress = _progress;
      final percent = progress == null ? null : (progress * 100).floor();
      return Padding(
        key: const Key('translate_offline_downloading'),
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(
                value: progress,
                strokeWidth: 2.5,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Semantics(
                liveRegion: true,
                child: Text(
                  _cancelled
                      ? l10n.offlineCancelling
                      : percent == null
                      ? l10n.translateOfflineDownloadingLanguageStarted(
                          current.name,
                        )
                      : l10n.translateOfflineDownloadingLanguage(
                          current.name,
                          percent,
                        ),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            ),
            if (_models?.state.canCancel ?? false)
              OfflineCancelDownloadButton(
                key: const Key('translate_offline_cancel'),
                language: current.name,
                onPressed: _cancelled ? null : () => unawaited(_cancel()),
              ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (error != null)
          Semantics(
            liveRegion: true,
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                error,
                key: const Key('translate_offline_download_error'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton.icon(
              key: const Key('translate_offline_download'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => unawaited(_download()),
              icon: const Icon(Icons.download_for_offline_outlined),
              label: Text(offlineDownloadLabel(l10n, widget.downloads)),
            ),
            manage,
          ],
        ),
      ],
    );
  }
}
