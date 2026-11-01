import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/image_translate/data/text_recognition_service.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/cubit/ocr_languages_cubit.dart';
import 'package:mozhi/offline/cubit/offline_models_state.dart';
import 'package:mozhi/offline/data/mirror_hosting.dart';
import 'package:mozhi/offline/data/offline_model_file_picker.dart';
import 'package:mozhi/offline/view/offline_models_page.dart'
    show MeteredDownloadDialog, offlineOutcomeMessage;
import 'package:mozhi/offline/widgets/mirror_hosting_banner.dart';
import 'package:mozhi/offline/widgets/ocr_import_summary.dart';
import 'package:mozhi/offline/widgets/ocr_manual_file_sheet.dart';
import 'package:mozhi/offline/widgets/offline_language_tile.dart';
import 'package:mozhi/settings/view/widgets/delete_local_data.dart'
    show formatStoredSize;
import 'package:mozhi/settings/view/widgets/empty_state_view.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';

/// Manage the language data of on-device text recognition (Tesseract):
/// sizes, downloads with progress (Wi-Fi only asks first on a metered
/// network, shared with the offline translation models), deletion,
/// imports from files without the network, and each language's file for
/// a download by hand. Opened from the offline languages screen.
///
/// Uses [store] when given, otherwise the [KeyValueStore] provided above
/// (falling back to the platform preferences); [picker] defaults to the
/// platform file picker.
class OcrLanguagesPage extends StatelessWidget {
  const new({required this.data, super.key, this.store, this.picker});

  final TextRecognitionLanguageData data;
  final KeyValueStore? store;
  final OfflineModelFilePicker? picker;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) {
        final cubit = OcrLanguagesCubit(
          data: data,
          store:
              store ?? _maybeRead<KeyValueStore>(context) ?? PreferencesStore(),
          picker: picker ?? const OfflineModelFilePicker(),
        );
        unawaited(cubit.load());
        return cubit;
      },
      child: const OcrLanguagesView(),
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

class OcrLanguagesView extends StatelessWidget {
  const new({super.key});

  Future<void> _onOutcome(
    BuildContext context,
    OfflineModelOutcome outcome,
  ) async {
    final cubit = context.read<OcrLanguagesCubit>();
    if (outcome.needsMeteredConsent) {
      final code = _codeOf(cubit.state, outcome.language);
      final size = cubit.state.item(code)?.ocr.downloadSize;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) =>
            MeteredDownloadDialog(language: outcome.language, size: size),
      );
      if (confirmed ?? false) {
        await cubit.download(code, overMeteredNetwork: true);
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
                  onPressed: () => unawaited(
                    cubit.download(_codeOf(cubit.state, outcome.language)),
                  ),
                )
              : null,
        ),
      );
  }

  /// The OCR code of the item displayed as [language].
  static String _codeOf(OcrLanguagesState state, OfflineLanguage language) {
    for (final item in state.languages) {
      if (item.display == language) return item.code;
    }
    return language.code;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return MultiBlocListener(
      listeners: [
        BlocListener<OcrLanguagesCubit, OcrLanguagesState>(
          listenWhen: (previous, current) =>
              current.outcome != null && previous.outcome != current.outcome,
          listener: (context, state) =>
              unawaited(_onOutcome(context, state.outcome!)),
        ),
        BlocListener<OcrLanguagesCubit, OcrLanguagesState>(
          listenWhen: (previous, current) =>
              current.importOutcome != null &&
              previous.importOutcome != current.importOutcome,
          listener: (context, state) {
            showDialog<void>(
              context: context,
              builder: (_) => OcrImportSummaryDialog(
                report: state.importOutcome!,
                nameOf: (code) =>
                    state.item(code)?.display.displayNameIn(l10n.localeName) ??
                    code,
              ),
            );
          },
        ),
      ],
      child: Scaffold(
        appBar: AppBar(title: Text(l10n.offlineOcrTitle)),
        body: BlocBuilder<OcrLanguagesCubit, OcrLanguagesState>(
          buildWhen: (previous, current) => previous.status != current.status,
          builder: (context, state) => switch (state.status) {
            OfflineModelsStatus.initial || OfflineModelsStatus.loading =>
              const Center(child: CircularProgressIndicator()),
            OfflineModelsStatus.failure => const _LoadFailure(),
            OfflineModelsStatus.ready => const _LanguagesList(),
          },
        ),
      ),
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
        onPressed: () => unawaited(context.read<OcrLanguagesCubit>().load()),
        icon: const Icon(Icons.refresh),
        label: Text(l10n.commonRetry),
      ),
    );
  }
}

class _LanguagesList extends StatelessWidget {
  const new();

  Future<void> _delete(BuildContext context, OcrLanguageItem item) async {
    final cubit = context.read<OcrLanguagesCubit>();
    final l10n = context.l10n;
    final body = l10n.offlineOcrDeleteBody(
      item.display.displayNameIn(l10n.localeName),
    );
    if (await confirmDeleteOfflineLanguage(context, item.display, body: body)) {
      await cubit.delete(item.code);
    }
  }

  @override
  Widget build(BuildContext context) => MirrorHostingBuilder(
    kind: MirrorDataKind.textRecognition,
    builder: _list,
  );

  /// The list; [blocked]: the web app's server does not host the data.
  Widget _list(BuildContext context, {required bool blocked}) {
    final l10n = context.l10n;
    final cubit = context.read<OcrLanguagesCubit>();
    final state = context.watch<OcrLanguagesCubit>().state;

    Widget tile(OcrLanguageItem item) {
      final code = item.code;
      return OfflineLanguageTile(
        key: ValueKey('ocr-$code'),
        language: item.display,
        downloaded: state.isInstalled(code),
        pending: state.pending[code],
        progress: state.progress[code],
        downloadSize: item.ocr.downloadSize,
        installedSize: state.installed[code],
        enabled: state.isAvailable,
        canDownload: !blocked,
        onDownload: () => unawaited(cubit.download(code)),
        onDelete: () => unawaited(_delete(context, item)),
        onCancel: state.canCancel
            ? () => unawaited(cubit.cancelDownload(code))
            : null,
        cancelling: state.cancelling.contains(code),
        onShowFiles: () => unawaited(
          showOcrManualFileSheet(
            context,
            language: item.display,
            data: item.ocr,
          ),
        ),
      );
    }

    List<Widget> rows(List<OcrLanguageItem> items) => [
      for (final (index, item) in items.indexed) ...[
        if (index > 0) const Hairline(indent: 72),
        tile(item),
      ],
    ];

    final installed = state.visibleInstalledIn(context.l10n.localeName);
    final available = state.visibleAvailableIn(context.l10n.localeName);
    return LayoutBuilder(
      builder: (context, constraints) => ListView(
        // Rows run edge to edge on phones (their content keeps a 16 dp
        // inset); wide windows keep the centered column.
        padding: centeredPadding(constraints.maxWidth)
            .subtract(const EdgeInsets.symmetric(horizontal: 16))
            .resolve(TextDirection.ltr),
        children: [
          if (!state.isAvailable) const _UnavailableBanner(),
          if (blocked && state.isAvailable)
            MirrorNotHostedBanner(
              importing: state.importing,
              onImport: () => unawaited(cubit.importFromFiles()),
            ),
          _Overview(state: state),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: _SearchField(),
          ),
          if (installed.isNotEmpty) ...[
            _SectionHeading(title: l10n.offlineSectionDownloaded),
            ...rows(installed),
            const Hairline(),
          ],
          if (available.isNotEmpty) ...[
            _SectionHeading(title: l10n.offlineSectionAvailable),
            ...rows(available),
          ],
          if (installed.isEmpty &&
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

class _Overview extends StatelessWidget {
  const new({required this.state});

  final OcrLanguagesState state;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final cubit = context.read<OcrLanguagesCubit>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            l10n.offlineDownloadedCount(state.installed.length),
            style: theme.textTheme.headlineSmall,
          ),
        ),
        if (state.totalBytes > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              l10n.offlineStorageUsed(formatStoredSize(l10n, state.totalBytes)),
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            l10n.offlineOcrDescription,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: palette.secondaryText,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 12,
            children: [
              Icon(
                Icons.verified_outlined,
                size: 20,
                color: palette.secondaryText,
              ),
              Expanded(
                child: Text(
                  l10n.offlineOcrSource,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: palette.secondaryText,
                  ),
                ),
              ),
            ],
          ),
        ),
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
              ? (enabled) => unawaited(cubit.setWifiOnly(enabled: enabled))
              : null,
        ),
        if (state.isAvailable)
          ListTile(
            key: const Key('offline_ocr_import'),
            leading: const Icon(Icons.file_open_outlined),
            title: Text(l10n.offlineImportAction),
            subtitle: Text(
              state.importing
                  ? l10n.offlineImporting
                  : l10n.offlineOcrImportSubtitle,
              style: TextStyle(
                color: state.importing
                    ? theme.colorScheme.primary
                    : palette.secondaryText,
              ),
            ),
            trailing: state.importing
                ? SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      semanticsLabel: l10n.offlineImporting,
                    ),
                  )
                : null,
            onTap: state.importing
                ? null
                : () => unawaited(cubit.importFromFiles()),
          ),
        const Hairline(),
      ],
    );
  }
}

class _UnavailableBanner extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: palette.hairline),
          borderRadius: AppLook.of(context).cardRadius,
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
                  context.l10n.offlineOcrUnavailable,
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

class _SearchField extends StatefulWidget {
  const new();

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  late final TextEditingController _controller = TextEditingController(
    text: context.read<OcrLanguagesCubit>().state.query,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _clear() {
    _controller.clear();
    context.read<OcrLanguagesCubit>().search('');
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
      onChanged: context.read<OcrLanguagesCubit>().search,
    );
  }
}
