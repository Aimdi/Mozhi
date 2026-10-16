import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/core/on_device_ml.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/cubit/offline_models_cubit.dart';
import 'package:mozhi/offline/widgets/offline_language_tile.dart';
import 'package:mozhi/platform/mlkit_bindings.dart'
    show createOfflineTranslator;
import 'package:mozhi/settings/view/widgets/empty_state_view.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';
import 'package:translation_repository/translation_repository.dart';

/// Manage the on-device (offline) translation models.
///
/// Uses [translator] and [store] when given, otherwise the
/// [OfflineTranslator] and [KeyValueStore] provided above (falling back to
/// [createOfflineTranslator] and the platform preferences).
class OfflineModelsPage extends StatelessWidget {
  const new({super.key, this.translator, this.store});

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
              createOfflineTranslator(),
          store:
              store ?? _maybeRead<KeyValueStore>(context) ?? PreferencesStore(),
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

  void _showOutcome(BuildContext context, OfflineModelOutcome outcome) {
    final l10n = context.l10n;
    final name = outcome.language.name;
    final message = switch ((outcome.operation, outcome.succeeded)) {
      (OfflineModelOperation.download, true) => l10n.offlineDownloadDone(name),
      (OfflineModelOperation.download, false) => l10n.offlineDownloadFailed(
        name,
      ),
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
          if (downloaded.isEmpty && available.isEmpty)
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
                  // Without ML Kit in the build (F-Droid) the platform is
                  // not the reason, so say what is missing instead.
                  mlKitIncluded
                      ? context.l10n.offlineUnavailable
                      : context.l10n.offlineNotIncluded,
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
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            l10n.offlineDescription,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: palette.secondaryText,
            ),
          ),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          secondary: const Icon(Icons.wifi),
          title: Text(l10n.offlineWifiOnly),
          subtitle: Text(
            l10n.offlineWifiOnlyDescription,
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
