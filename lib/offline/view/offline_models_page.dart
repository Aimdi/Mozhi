import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mlkit_translator/mlkit_translator.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/cubit/offline_models_cubit.dart';
import 'package:mozhi/offline/widgets/offline_language_tile.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';
import 'package:translation_repository/translation_repository.dart';

/// Manage the on-device (offline) translation models.
///
/// Uses [translator] and [store] when given, otherwise the
/// [OfflineTranslator] and [KeyValueStore] provided above (falling back to
/// a new [MlKitOfflineTranslator] and the platform preferences).
class OfflineModelsPage extends StatelessWidget {
  const OfflineModelsPage({super.key, this.translator, this.store});

  final OfflineTranslator? translator;
  final KeyValueStore? store;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) {
        final cubit = OfflineModelsCubit(
          translator:
              translator ??
              _maybeRead<OfflineTranslator>(context) ??
              MlKitOfflineTranslator(),
          store: store ?? _maybeRead<KeyValueStore>(context) ?? PreferencesStore(),
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
  const OfflineModelsView({super.key});

  void _showOutcome(BuildContext context, OfflineModelOutcome outcome) {
    final l10n = context.l10n;
    final name = outcome.language.name;
    final message = switch ((outcome.operation, outcome.succeeded)) {
      (OfflineModelOperation.download, true) => l10n.offlineDownloadDone(name),
      (OfflineModelOperation.download, false) =>
        l10n.offlineDownloadFailed(name),
      (OfflineModelOperation.delete, true) => l10n.offlineDeleteDone(name),
      (OfflineModelOperation.delete, false) => l10n.offlineDeleteFailed(name),
    };
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return BlocListener<OfflineModelsCubit, OfflineModelsState>(
      listenWhen: (previous, current) =>
          current.outcome != null && previous.outcome != current.outcome,
      listener: (context, state) => _showOutcome(context, state.outcome!),
      child: Scaffold(
        appBar: AppBar(title: Text(l10n.offlineTitle)),
        body: BlocBuilder<OfflineModelsCubit, OfflineModelsState>(
          buildWhen: (previous, current) => previous.status != current.status,
          builder: (context, state) => switch (state.status) {
            OfflineModelsStatus.initial ||
            OfflineModelsStatus.loading => const Center(
              child: CircularProgressIndicator(),
            ),
            OfflineModelsStatus.failure => const _LoadFailure(),
            OfflineModelsStatus.ready => const _ModelsList(),
          },
        ),
      ),
    );
  }
}

class _LoadFailure extends StatelessWidget {
  const _LoadFailure();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 48,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              l10n.offlineLoadFailed,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: () =>
                  unawaited(context.read<OfflineModelsCubit>().load()),
              icon: const Icon(Icons.refresh),
              label: Text(l10n.commonRetry),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModelsList extends StatelessWidget {
  const _ModelsList();

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

    Widget tile(OfflineLanguage language) => OfflineLanguageTile(
      key: ValueKey('offline-${language.code}'),
      language: language,
      downloaded: state.isDownloaded(language.code),
      pending: state.pending[language.code],
      wifiOnly: state.wifiOnly,
      enabled: state.isAvailable,
      onDownload: () => unawaited(cubit.download(language.code)),
      onDelete: () => unawaited(_delete(context, language)),
    );

    final downloaded = state.visibleDownloaded;
    final available = state.visibleAvailable;
    return LayoutBuilder(
      builder: (context, constraints) => ListView(
        padding: centeredPadding(constraints.maxWidth),
        children: [
          if (!state.isAvailable) const _UnavailableBanner(),
          _Overview(state: state),
          const SizedBox(height: 16),
          const _SearchField(),
          const SizedBox(height: 16),
          if (downloaded.isNotEmpty)
            SettingsSection(
              title: l10n.offlineSectionDownloaded,
              children: [for (final language in downloaded) tile(language)],
            ),
          if (available.isNotEmpty)
            SettingsSection(
              title: l10n.offlineSectionAvailable,
              children: [for (final language in available) tile(language)],
            ),
          if (downloaded.isEmpty && available.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                l10n.offlineNoMatches(state.query.trim()),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
        ],
      ),
    );
  }
}

class _UnavailableBanner extends StatelessWidget {
  const _UnavailableBanner();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card.filled(
        margin: EdgeInsets.zero,
        color: colors.secondaryContainer,
        child: ListTile(
          leading: Icon(
            Icons.info_outline,
            color: colors.onSecondaryContainer,
          ),
          title: Text(
            context.l10n.offlineUnavailable,
            style: TextStyle(color: colors.onSecondaryContainer),
          ),
        ),
      ),
    );
  }
}

class _Overview extends StatelessWidget {
  const _Overview({required this.state});

  final OfflineModelsState state;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Card.filled(
      margin: EdgeInsets.zero,
      color: theme.colorScheme.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(l10n.offlineDescription),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              l10n.offlineDownloadedCount(state.downloadedCount),
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.wifi),
            title: Text(l10n.offlineWifiOnly),
            subtitle: Text(l10n.offlineWifiOnlyDescription),
            value: state.wifiOnly,
            onChanged: state.isAvailable
                ? (enabled) => unawaited(
                    context.read<OfflineModelsCubit>().setWifiOnly(
                      enabled: enabled,
                    ),
                  )
                : null,
          ),
        ],
      ),
    );
  }
}

class _SearchField extends StatefulWidget {
  const _SearchField();

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
