import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/core/network/network_policy.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/cubit/offline_models_cubit.dart';
import 'package:mozhi/offline/data/bergamot_model_details.dart';
import 'package:mozhi/offline/data/offline_model_details.dart';
import 'package:mozhi/offline/data/offline_model_error.dart';
import 'package:mozhi/offline/data/unavailable_offline_translator.dart';
import 'package:mozhi/offline/widgets/offline_language_tile.dart';
import 'package:mozhi/settings/view/widgets/delete_local_data.dart'
    show formatStoredSize;
import 'package:mozhi/settings/view/widgets/empty_state_view.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';
import 'package:translation_repository/translation_repository.dart';

/// Manage the on-device (offline) translation models: Mozilla's Firefox
/// Translations models, with sizes, progress, updates and the metered
/// network prompt.
///
/// Uses [translator] and [store] when given, otherwise the
/// [OfflineTranslator] and [KeyValueStore] provided above (falling back to
/// an [UnavailableOfflineTranslator] and the platform preferences).
/// [details] defaults to [offlineModelDetailsOf] the translator.
class OfflineModelsPage extends StatelessWidget {
  const new({super.key, this.translator, this.store, this.details});

  final OfflineTranslator? translator;
  final KeyValueStore? store;
  final OfflineModelDetails? details;

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
        );
        unawaited(cubit.load());
        return cubit;
      },
      child: const OfflineModelsView(),
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
  const new({super.key});

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
    return BlocListener<OfflineModelsCubit, OfflineModelsState>(
      listenWhen: (previous, current) =>
          current.outcome != null && previous.outcome != current.outcome,
      listener: (context, state) =>
          unawaited(_onOutcome(context, state.outcome!)),
      child: Scaffold(
        appBar: AppBar(title: Text(l10n.offlineTitle)),
        body: BlocBuilder<OfflineModelsCubit, OfflineModelsState>(
          buildWhen: (previous, current) => previous.status != current.status,
          builder: (context, state) => switch (state.status) {
            OfflineModelsStatus.initial || OfflineModelsStatus.loading =>
              const Center(child: CircularProgressIndicator()),
            OfflineModelsStatus.failure => const _LoadFailure(),
            OfflineModelsStatus.ready => const _ModelsList(),
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
  return switch (error.kind) {
    OfflineModelErrorKind.checksum => l10n.offlineErrorChecksum(name),
    OfflineModelErrorKind.server => l10n.offlineErrorServer(
      name,
      error.statusCode ?? 0,
    ),
    OfflineModelErrorKind.network => switch (error.networkPolicy) {
      NetworkPolicyError.cleartext => l10n.commonErrorCleartextRefused,
      NetworkPolicyError.proxyRequired => l10n.commonErrorProxyRequired,
      NetworkPolicyError.invalidProxy => l10n.commonErrorInvalidProxy,
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
      title: Text(
        l10n.offlineMeteredTitle,
        style: theme.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w800,
        ),
      ),
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
          style: FilledButton.styleFrom(
            shape: const StadiumBorder(),
            textStyle: const TextStyle(fontWeight: FontWeight.w700),
          ),
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
        style: FilledButton.styleFrom(shape: const StadiumBorder()),
        onPressed: () => unawaited(context.read<OfflineModelsCubit>().load()),
        icon: const Icon(Icons.refresh),
        label: Text(l10n.commonRetry),
      ),
    );
  }
}

class _ModelsList extends StatelessWidget {
  const new();

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
          if (!state.isAvailable) const _UnavailableBanner(),
          _Overview(state: state),
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
          // An engine without languages (web, desktop) only shows the banner.
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
        child: Text(
          title,
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.3),
        ),
      ),
    );
  }
}

class _UnavailableBanner extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    // In the Android app the engine is always built in, so only the CPU can
    // be the reason; elsewhere (web, desktop) the platform is.
    final android = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: palette.hairline),
          borderRadius: BorderRadius.circular(16),
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
                  android
                      ? context.l10n.offlineUnavailableDevice
                      : context.l10n.offlineUnavailableApp,
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
  const new({required this.state});

  final OfflineModelsState state;

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
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              letterSpacing: -0.4,
            ),
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
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(l10n.offlineDescriptionMozilla, style: secondary),
        ),
        if (state.hasDetails) ...[
          _Note(icon: Icons.alt_route, text: l10n.offlineViaEnglish),
          _Note(icon: Icons.verified_outlined, text: l10n.offlineModelSource),
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
        const Hairline(),
      ],
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
