import 'dart:async';

import 'package:bergamot_translator/bergamot_translator.dart'
    show BergamotWebRequirement;
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/core/network/network_policy.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/dictionary/data/default_dictionary_packs.dart'
    show maybeDictionaryPacks;
import 'package:mozhi/image_translate/data/text_recognition_service.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/cubit/offline_models_cubit.dart';
import 'package:mozhi/offline/data/bergamot_model_details.dart';
import 'package:mozhi/offline/data/offline_model_details.dart';
import 'package:mozhi/offline/data/offline_model_error.dart';
import 'package:mozhi/offline/data/offline_model_file_picker.dart';
import 'package:mozhi/offline/data/unavailable_offline_translator.dart';
import 'package:mozhi/offline/view/dictionary_packs_page.dart'
    show DictionaryPacksEntry;
import 'package:mozhi/offline/view/ocr_languages_page.dart';
import 'package:mozhi/offline/widgets/offline_import_summary.dart';
import 'package:mozhi/offline/widgets/offline_language_tile.dart';
import 'package:mozhi/offline/widgets/offline_manual_files_sheet.dart';
import 'package:mozhi/platform/mlkit_bindings.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart' show ModelSource;
import 'package:mozhi/settings/view/widgets/delete_local_data.dart'
    show formatStoredSize;
import 'package:mozhi/settings/view/widgets/empty_state_view.dart';
import 'package:mozhi/settings/view/widgets/model_source_dialog.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';
import 'package:translation_repository/translation_repository.dart';

/// Manage the on-device (offline) translation models: Mozilla's Firefox
/// Translations models, with sizes, progress, updates, the metered network
/// prompt, and imports from files (no network) with the files to download
/// by hand per language. Links to the text recognition languages
/// ([OcrLanguagesPage]) when the build's recognizer downloads data per
/// language and runs here.
///
/// Uses [translator] and [store] when given, otherwise the
/// [OfflineTranslator] and [KeyValueStore] provided above (falling back to
/// an [UnavailableOfflineTranslator] and the platform preferences).
/// [details] defaults to [offlineModelDetailsOf] the translator (which also
/// imports), [picker] to the platform file picker, [textRecognition] to
/// the language data of the build's recognizer
/// ([createTextRecognitionService]; none with ML Kit).
class OfflineModelsPage extends StatelessWidget {
  const new({
    super.key,
    this.translator,
    this.store,
    this.details,
    this.picker,
    this.textRecognition,
  });

  final OfflineTranslator? translator;
  final KeyValueStore? store;
  final OfflineModelDetails? details;
  final OfflineModelFilePicker? picker;
  final TextRecognitionLanguageData? textRecognition;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) {
        final engine =
            translator ??
            _maybeRead<OfflineTranslator>(context) ??
            const UnavailableOfflineTranslator();
        final cubit = OfflineModelsCubit(
          translator: engine,
          store:
              store ?? _maybeRead<KeyValueStore>(context) ?? PreferencesStore(),
          details: details ?? offlineModelDetailsOf(engine),
          picker: picker ?? const OfflineModelFilePicker(),
        );
        unawaited(cubit.load());
        return cubit;
      },
      child: OfflineModelsView(
        textRecognition:
            textRecognition ??
            textRecognitionLanguageDataOf(createTextRecognitionService()),
        webRequirement: switch (translator ??
            _maybeRead<OfflineTranslator>(context)) {
          final UnavailableOfflineTranslator unavailable =>
            unavailable.webRequirement,
          _ => null,
        },
      ),
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

class OfflineModelsView extends StatelessWidget {
  const new({super.key, this.textRecognition, this.webRequirement});

  /// The text recognition languages to link to, if any.
  final TextRecognitionLanguageData? textRecognition;

  /// In the web app without an on-device engine: what the browser lacks
  /// (the banner says so).
  final BergamotWebRequirement? webRequirement;

  Future<void> _onOutcome(
    BuildContext context,
    OfflineModelOutcome outcome,
  ) async {
    final cubit = context.read<OfflineModelsCubit>();
    if (outcome.needsMeteredConsent) {
      final size = cubit.state.downloadSizeOf(outcome.language.code);
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) =>
            MeteredDownloadDialog(language: outcome.language, size: size),
      );
      if (confirmed ?? false) {
        await cubit.download(outcome.language.code, overMeteredNetwork: true);
      }
      return;
    }
    if (!context.mounted) return;
    final l10n = context.l10n;
    final retry =
        !outcome.succeeded && outcome.operation != OfflineModelOperation.delete;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(offlineOutcomeMessage(l10n, outcome)),
          action: retry
              ? SnackBarAction(
                  label: l10n.commonRetry,
                  onPressed: () =>
                      unawaited(cubit.download(outcome.language.code)),
                )
              : null,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return MultiBlocListener(
      listeners: [
        BlocListener<OfflineModelsCubit, OfflineModelsState>(
          listenWhen: (previous, current) =>
              current.outcome != null && previous.outcome != current.outcome,
          listener: (context, state) =>
              unawaited(_onOutcome(context, state.outcome!)),
        ),
        BlocListener<OfflineModelsCubit, OfflineModelsState>(
          listenWhen: (previous, current) =>
              current.importOutcome != null &&
              previous.importOutcome != current.importOutcome,
          listener: (context, state) {
            showDialog<void>(
              context: context,
              builder: (_) =>
                  OfflineImportSummaryDialog(outcome: state.importOutcome!),
            );
          },
        ),
      ],
      child: Scaffold(
        appBar: AppBar(title: Text(l10n.offlineTitle)),
        body: BlocBuilder<OfflineModelsCubit, OfflineModelsState>(
          buildWhen: (previous, current) => previous.status != current.status,
          builder: (context, state) => switch (state.status) {
            OfflineModelsStatus.initial || OfflineModelsStatus.loading =>
              const Center(child: CircularProgressIndicator()),
            OfflineModelsStatus.failure => const _LoadFailure(),
            OfflineModelsStatus.ready => _ModelsList(
              textRecognition: textRecognition,
              webRequirement: webRequirement,
            ),
          },
        ),
      ),
    );
  }
}

/// The message for a finished operation: what happened or, for a failure,
/// why (a damaged download, a server error, no connection, a full disk, the
/// engine).
String offlineOutcomeMessage(
  AppLocalizations l10n,
  OfflineModelOutcome outcome,
) {
  final name = outcome.language.name;
  final error = outcome.error;
  if (outcome.succeeded || error == null) {
    return switch ((outcome.operation, outcome.succeeded)) {
      (OfflineModelOperation.download, true) => l10n.offlineDownloadDone(name),
      (OfflineModelOperation.update, true) => l10n.offlineUpdateDone(name),
      (OfflineModelOperation.delete, true) => l10n.offlineDeleteDone(name),
      (OfflineModelOperation.download, false) => l10n.offlineDownloadFailed(
        name,
      ),
      (OfflineModelOperation.update, false) => l10n.offlineUpdateFailed(name),
      (OfflineModelOperation.delete, false) => l10n.offlineDeleteFailed(name),
    };
  }
  final mirror = error.mirror;
  return switch (error.kind) {
    OfflineModelErrorKind.checksum when mirror != null =>
      l10n.offlineErrorChecksumMirror(name, mirror),
    OfflineModelErrorKind.checksum => l10n.offlineErrorChecksum(name),
    OfflineModelErrorKind.server when mirror != null =>
      l10n.offlineErrorServerMirror(name, mirror, error.statusCode ?? 0),
    OfflineModelErrorKind.server => l10n.offlineErrorServer(
      name,
      error.statusCode ?? 0,
    ),
    OfflineModelErrorKind.network => switch (error.networkPolicy) {
      NetworkPolicyError.cleartext => l10n.commonErrorCleartextRefused,
      NetworkPolicyError.proxyRequired => l10n.commonErrorProxyRequired,
      NetworkPolicyError.invalidProxy => l10n.commonErrorInvalidProxy,
      null when mirror != null => l10n.offlineErrorNetworkMirror(name, mirror),
      null => l10n.offlineErrorNetwork(name),
    },
    OfflineModelErrorKind.storage => l10n.offlineErrorStorage(name),
    OfflineModelErrorKind.engine => l10n.offlineErrorEngine(name),
    OfflineModelErrorKind.unsupported => l10n.offlineErrorUnsupported(name),
    OfflineModelErrorKind.metered ||
    OfflineModelErrorKind.unknown => switch (outcome.operation) {
      OfflineModelOperation.download => l10n.offlineDownloadFailed(name),
      OfflineModelOperation.update => l10n.offlineUpdateFailed(name),
      OfflineModelOperation.delete => l10n.offlineDeleteFailed(name),
    },
  };
}

/// "Download over mobile data?": true when the user chose to download
/// anyway.
class MeteredDownloadDialog extends StatelessWidget {
  const new({required this.language, this.size, super.key});

  final OfflineLanguage language;

  /// Bytes to download, when known.
  final int? size;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final size = this.size;
    return AlertDialog(
      icon: const Icon(Icons.signal_cellular_alt),
      title: Text(l10n.offlineMeteredTitle, style: theme.textTheme.titleLarge),
      content: Text(
        size == null || size == 0
            ? l10n.offlineMeteredBodyUnknownSize(language.name)
            : l10n.offlineMeteredBody(
                language.name,
                formatStoredSize(l10n, size),
              ),
        style: theme.textTheme.bodyMedium?.copyWith(
          color: AppPalette.of(context).secondaryText,
        ),
      ),
      actionsOverflowButtonSpacing: 8,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.offlineMeteredDownloadAnyway),
        ),
      ],
    );
  }
}

class _LoadFailure extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return EmptyStateView(
      icon: Icons.cloud_off_outlined,
      tone: EmptyStateTone.error,
      title: l10n.offlineLoadFailed,
      announce: true,
      action: FilledButton.icon(
        onPressed: () => unawaited(context.read<OfflineModelsCubit>().load()),
        icon: const Icon(Icons.refresh),
        label: Text(l10n.commonRetry),
      ),
    );
  }
}

class _ModelsList extends StatelessWidget {
  const new({this.textRecognition, this.webRequirement});

  final TextRecognitionLanguageData? textRecognition;
  final BergamotWebRequirement? webRequirement;

  Future<void> _delete(BuildContext context, OfflineLanguage language) async {
    final cubit = context.read<OfflineModelsCubit>();
    if (await confirmDeleteOfflineLanguage(context, language)) {
      await cubit.delete(language.code);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<OfflineModelsCubit>();
    final state = context.watch<OfflineModelsCubit>().state;

    Widget tile(OfflineLanguage language) {
      final code = language.code;
      return OfflineLanguageTile(
        key: ValueKey('offline-$code'),
        language: language,
        downloaded: state.isDownloaded(code),
        pending: state.pending[code],
        progress: state.progress[code],
        downloadSize: state.downloadSizeOf(code),
        installedSize: state.installedSizeOf(code),
        outdated: state.isOutdated(code),
        builtIn: state.isBuiltIn(code),
        enabled: state.isAvailable,
        onDownload: () => unawaited(cubit.download(code)),
        onDelete: () => unawaited(_delete(context, language)),
        onShowFiles: switch (state.manualDownloadsOf(code)) {
          final directions when directions.isNotEmpty => () => unawaited(
            showOfflineManualFilesSheet(
              context,
              language: language,
              directions: directions,
            ),
          ),
          _ => null,
        },
      );
    }

    List<Widget> rows(List<OfflineLanguage> languages) => [
      for (final (index, language) in languages.indexed) ...[
        if (index > 0) const Hairline(indent: 72),
        tile(language),
      ],
    ];

    final downloaded = state.visibleDownloaded;
    final available = state.visibleAvailable;
    return LayoutBuilder(
      builder: (context, constraints) => ListView(
        // Rows run edge to edge on phones (their content keeps a 16 dp
        // inset); wide windows keep the centered column.
        padding: centeredPadding(constraints.maxWidth)
            .subtract(const EdgeInsets.symmetric(horizontal: 16))
            .resolve(TextDirection.ltr),
        children: [
          if (!state.isAvailable)
            _UnavailableBanner(webRequirement: webRequirement),
          _Overview(state: state, textRecognition: textRecognition),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: _SearchField(),
          ),
          if (downloaded.isNotEmpty) ...[
            _SectionHeading(title: l10n.offlineSectionDownloaded),
            ...rows(downloaded),
            const Hairline(),
          ],
          if (available.isNotEmpty) ...[
            _SectionHeading(title: l10n.offlineSectionAvailable),
            ...rows(available),
          ],
          // An engine without languages (a browser without the engine's
          // needs, desktop) only shows the banner.
          if (downloaded.isEmpty &&
              available.isEmpty &&
              state.languages.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                l10n.offlineNoMatches(state.query.trim()),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge
                    ?.copyWith(color: AppPalette.of(context).secondaryText),
              ),
            ),
        ],
      ),
    );
  }
}

/// A bold X-style section heading.
class _SectionHeading extends StatelessWidget {
  const new({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Semantics(
        header: true,
        child: Text(title, style: Theme.of(context).textTheme.titleLarge),
      ),
    );
  }
}

class _UnavailableBanner extends StatelessWidget {
  const new({this.webRequirement});

  /// What the browser lacks, in the web app.
  final BergamotWebRequirement? webRequirement;

  /// Why on-device translation does not work here.
  static String message(
    AppLocalizations l10n,
    BergamotWebRequirement? webRequirement,
  ) {
    if (webRequirement != null) {
      return switch (webRequirement) {
        BergamotWebRequirement.engineFiles =>
          l10n.offlineUnavailableWebEngineMissing,
        BergamotWebRequirement.secureContext =>
          l10n.offlineUnavailableWebInsecure,
        BergamotWebRequirement.storage => l10n.offlineUnavailableWebStorage,
        BergamotWebRequirement.wasmSimd ||
        BergamotWebRequirement.decompression ||
        BergamotWebRequirement.segmenter => l10n.offlineUnavailableWebOutdated,
      };
    }
    // In the Android app the engine is always built in, so only the CPU can
    // be the reason; elsewhere (desktop) the platform is.
    final android = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    return android ? l10n.offlineUnavailableDevice : l10n.offlineUnavailableApp;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: palette.hairline),
          borderRadius: AppRadius.cardBorderRadius,
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 12,
            children: [
              Icon(Icons.info_outline, color: theme.colorScheme.primary),
              Expanded(
                child: Text(
                  message(context.l10n, webRequirement),
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Overview extends StatelessWidget {
  const new({required this.state, this.textRecognition});

  final OfflineModelsState state;
  final TextRecognitionLanguageData? textRecognition;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final secondary = theme.textTheme.bodyMedium?.copyWith(
      color: palette.secondaryText,
    );
    final storage = state.storage;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            l10n.offlineDownloadedCount(state.downloadedCount),
            style: theme.textTheme.headlineSmall,
          ),
        ),
        if (storage != null && storage.totalBytes > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              l10n.offlineStorageUsed(
                formatStoredSize(l10n, storage.totalBytes),
              ),
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(l10n.offlineDescriptionMozilla, style: secondary),
        ),
        if (state.hasDetails) ...[
          _Note(icon: Icons.alt_route, text: l10n.offlineViaEnglish),
          _Note(
            icon: Icons.verified_outlined,
            text: switch (modelSourceHost(_modelSource(context))) {
              final host? => l10n.offlineModelSourceMirror(host),
              null => l10n.offlineModelSource,
            },
          ),
          if (kIsWeb && state.isAvailable)
            _Note(icon: Icons.web_outlined, text: l10n.offlineWebStorageNote),
        ],
        const SizedBox(height: 8),
        SwitchListTile(
          secondary: const Icon(Icons.wifi),
          title: Text(l10n.offlineWifiOnly),
          subtitle: Text(
            l10n.offlineWifiOnlyAsk,
            style: TextStyle(color: palette.secondaryText),
          ),
          value: state.wifiOnly,
          onChanged: state.isAvailable
              ? (enabled) => unawaited(
                  context.read<OfflineModelsCubit>().setWifiOnly(
                    enabled: enabled,
                  ),
                )
              : null,
        ),
        // Where this page's (and voice input's) models come from.
        const ModelSourceTile(),
        if (state.canImport) _ImportTile(importing: state.importing),
        if (textRecognition case final data? when data.isSupported)
          OcrLanguagesEntry(data: data),
        if (maybeDictionaryPacks(context) case final packs?)
          DictionaryPacksEntry(packs: packs),
        const Hairline(),
      ],
    );
  }
}

/// The model source in use: the settings' (rebuilding when it changes),
/// else [ModelSource.current].
ModelSource _modelSource(BuildContext context) {
  try {
    return context.select<SettingsCubit, ModelSource>(
      (cubit) => cubit.state.modelSource,
    );
  } on ProviderNotFoundException {
    return ModelSource.current;
  }
}

/// "Import from files": picks model files and installs them, without the
/// network.
class _ImportTile extends StatelessWidget {
  const new({required this.importing});

  final bool importing;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    return ListTile(
      key: const Key('offline_import'),
      leading: const Icon(Icons.file_open_outlined),
      title: Text(l10n.offlineImportAction),
      subtitle: Text(
        importing ? l10n.offlineImporting : l10n.offlineImportSubtitle,
        style: TextStyle(
          color: importing ? theme.colorScheme.primary : palette.secondaryText,
        ),
      ),
      trailing: importing
          ? SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                semanticsLabel: l10n.offlineImporting,
              ),
            )
          : null,
      onTap: importing
          ? null
          : () =>
                unawaited(context.read<OfflineModelsCubit>().importFromFiles()),
    );
  }
}

/// A small explanatory line with a leading icon.
class _Note extends StatelessWidget {
  const new({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          Icon(icon, size: 20, color: palette.secondaryText),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: palette.secondaryText,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchField extends StatefulWidget {
  const new();

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  late final TextEditingController _controller = TextEditingController(
    text: context.read<OfflineModelsCubit>().state.query,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _clear() {
    _controller.clear();
    context.read<OfflineModelsCubit>().search('');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SearchBar(
      controller: _controller,
      hintText: l10n.offlineSearchHint,
      elevation: const WidgetStatePropertyAll(0),
      leading: const Icon(Icons.search),
      trailing: [
        ListenableBuilder(
          listenable: _controller,
          builder: (context, _) => _controller.text.isEmpty
              ? const SizedBox.shrink()
              : IconButton(
                  tooltip: l10n.commonClear,
                  icon: const Icon(Icons.close),
                  onPressed: _clear,
                ),
        ),
      ],
      onChanged: context.read<OfflineModelsCubit>().search,
    );
  }
}

/// "Text recognition": opens the text recognition languages
/// ([OcrLanguagesPage]); says how many are downloaded.
class OcrLanguagesEntry extends StatefulWidget {
  const new({required this.data, super.key});

  final TextRecognitionLanguageData data;

  @override
  State<OcrLanguagesEntry> createState() => _OcrLanguagesEntryState();
}

class _OcrLanguagesEntryState extends State<OcrLanguagesEntry> {
  StreamSubscription<void>? _changes;
  int? _count;

  @override
  void initState() {
    super.initState();
    _changes = widget.data.ocrLanguagesChanged.listen((_) => _load());
    _load();
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
  }

  void _load() {
    unawaited(
      widget.data.installedOcrLanguages().then(
        (installed) {
          if (mounted) setState(() => _count = installed.length);
        },
        onError: (Object _) {
          // The count is a hint; the page itself reports failures.
        },
      ),
    );
  }

  void _open(BuildContext context) {
    final store = OfflineModelsPage._maybeRead<KeyValueStore>(context);
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => OcrLanguagesPage(data: widget.data, store: store),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListTile(
      key: const Key('offline_ocr'),
      leading: const Icon(Icons.document_scanner_outlined),
      title: Text(l10n.offlineOcrTitle),
      subtitle: Text(
        l10n.offlineOcrEntrySubtitle(_count ?? 0),
        style: TextStyle(color: AppPalette.of(context).secondaryText),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _open(context),
    );
  }
}
