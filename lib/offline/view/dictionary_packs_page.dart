import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/dictionary/data/dictionary_packs.dart';
import 'package:mozhi/dictionary/widgets/dictionary_attribution.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/cubit/dictionary_packs_cubit.dart';
import 'package:mozhi/offline/cubit/offline_models_state.dart';
import 'package:mozhi/offline/data/mirror_hosting.dart';
import 'package:mozhi/offline/data/offline_model_file_picker.dart';
import 'package:mozhi/offline/view/offline_models_page.dart'
    show MeteredDownloadDialog, offlineOutcomeMessage;
import 'package:mozhi/offline/widgets/dictionary_import_summary.dart';
import 'package:mozhi/offline/widgets/mirror_hosting_banner.dart';
import 'package:mozhi/offline/widgets/offline_language_tile.dart';
import 'package:mozhi/settings/view/widgets/delete_local_data.dart'
    show formatStoredSize;
import 'package:mozhi/settings/view/widgets/empty_state_view.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';

/// Manage the offline dictionaries (Wiktionary packs for the Dictionary
/// tab and short translations): sizes, downloads with progress (Wi-Fi
/// only asks first on a metered network, shared with the offline
/// translation models), updates and deletion. Opened from the offline
/// languages screen and from the Dictionary tab.
///
/// Uses [store] when given, otherwise the [KeyValueStore] provided above
/// (falling back to the platform preferences).
class DictionaryPacksPage extends StatelessWidget {
  const new({required this.packs, super.key, this.store, this.picker});

  final DictionaryPacks packs;
  final KeyValueStore? store;

  /// Picks the files of "Import from files" (default: the platform's).
  final OfflineModelFilePicker? picker;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) {
        final cubit = DictionaryPacksCubit(
          packs: packs,
          store: store ?? _maybeStore(context) ?? PreferencesStore(),
          picker: picker ?? const OfflineModelFilePicker(),
        );
        unawaited(cubit.load());
        return cubit;
      },
      child: const DictionaryPacksView(),
    );
  }

  static KeyValueStore? _maybeStore(BuildContext context) {
    try {
      return context.read<KeyValueStore>();
    } on ProviderNotFoundException {
      return null;
    }
  }
}

/// Opens the dictionaries screen ([DictionaryPacksPage]) for [packs].
Future<void> openDictionaryPacks(BuildContext context, DictionaryPacks packs) =>
    Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => DictionaryPacksPage(packs: packs)),
    );

class DictionaryPacksView extends StatelessWidget {
  const new({super.key});

  Future<void> _onOutcome(
    BuildContext context,
    OfflineModelOutcome outcome,
  ) async {
    final cubit = context.read<DictionaryPacksCubit>();
    final id = outcome.language.code;
    if (outcome.needsMeteredConsent) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => MeteredDownloadDialog(
          language: outcome.language,
          size: cubit.state.item(id)?.pack.size,
        ),
      );
      if (confirmed ?? false) {
        await cubit.download(id, overMeteredNetwork: true);
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
                  onPressed: () => unawaited(cubit.download(id)),
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
        BlocListener<DictionaryPacksCubit, DictionaryPacksState>(
          listenWhen: (previous, current) =>
              current.outcome != null && previous.outcome != current.outcome,
          listener: (context, state) =>
              unawaited(_onOutcome(context, state.outcome!)),
        ),
        // What an import from files did.
        BlocListener<DictionaryPacksCubit, DictionaryPacksState>(
          listenWhen: (previous, current) =>
              current.importOutcome != null &&
              previous.importOutcome != current.importOutcome,
          listener: (context, state) => showDialog<void>(
            context: context,
            builder: (_) => DictionaryImportSummaryDialog(
              outcome: state.importOutcome!,
              nameOf: (pack) =>
                  state.item(pack.id)?.display.displayNameIn(l10n.localeName) ??
                  pack.name,
            ),
          ),
        ),
      ],
      child: Scaffold(
        appBar: AppBar(title: Text(l10n.offlineDictionariesTitle)),
        body: BlocBuilder<DictionaryPacksCubit, DictionaryPacksState>(
          buildWhen: (previous, current) => previous.status != current.status,
          builder: (context, state) => switch (state.status) {
            OfflineModelsStatus.initial || OfflineModelsStatus.loading =>
              const Center(child: CircularProgressIndicator()),
            OfflineModelsStatus.failure => const _LoadFailure(),
            OfflineModelsStatus.ready => const _PacksList(),
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
        onPressed: () => unawaited(context.read<DictionaryPacksCubit>().load()),
        icon: const Icon(Icons.refresh),
        label: Text(l10n.commonRetry),
      ),
    );
  }
}

class _PacksList extends StatelessWidget {
  const new();

  Future<void> _delete(BuildContext context, DictionaryPackItem item) async {
    final cubit = context.read<DictionaryPacksCubit>();
    final l10n = context.l10n;
    final body = l10n.offlineDictionariesDeleteBody(
      item.display.displayNameIn(l10n.localeName),
    );
    if (await confirmDeleteOfflineLanguage(context, item.display, body: body)) {
      await cubit.delete(item.id);
    }
  }

  @override
  Widget build(BuildContext context) =>
      MirrorHostingBuilder(kind: MirrorDataKind.dictionary, builder: _list);

  /// The list; [blocked]: the web app's server does not host the packs.
  Widget _list(BuildContext context, {required bool blocked}) {
    final l10n = context.l10n;
    final cubit = context.read<DictionaryPacksCubit>();
    final state = context.watch<DictionaryPacksCubit>().state;

    Widget tile(DictionaryPackItem item) {
      final id = item.id;
      return OfflineLanguageTile(
        key: ValueKey('dictionary-pack-$id'),
        language: item.display,
        downloaded: state.isInstalled(id),
        pending: state.pending[id],
        progress: state.progress[id],
        downloadSize: item.pack.size,
        installedSize: state.installed[id]?.size,
        outdated: state.isOutdated(id),
        enabled: state.isAvailable,
        canDownload: !blocked,
        note: l10n.dictionaryDefinitionsIn(
          context.languageNameOf(item.pack.glossLanguage),
        ),
        onDownload: () => unawaited(cubit.download(id)),
        onDelete: () => unawaited(_delete(context, item)),
        onCancel: () => unawaited(cubit.cancelDownload(id)),
        cancelling: state.cancelling.contains(id),
      );
    }

    List<Widget> rows(List<DictionaryPackItem> items) => [
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
              onImport: state.canImport
                  ? () => unawaited(cubit.importFromFiles())
                  : null,
            ),
          _Overview(state: state),
          if (state.packs.isEmpty)
            EmptyStateView(
              key: const Key('dictionary_packs_empty'),
              icon: Icons.menu_book_outlined,
              title: l10n.offlineDictionariesEmptyTitle,
              body: l10n.offlineDictionariesEmptyBody,
              compact: true,
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
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
          if (installed.isEmpty && available.isEmpty && state.packs.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                l10n.offlineNoMatches(state.query.trim()),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge
                    ?.copyWith(color: AppPalette.of(context).secondaryText),
              ),
            ),
          if (state.canImport) ...[
            const Hairline(),
            _ImportTile(importing: state.importing),
          ],
        ],
      ),
    );
  }
}

/// "Import from files": picks dictionary pack files and installs them,
/// without the network.
class _ImportTile extends StatelessWidget {
  const new({required this.importing});

  final bool importing;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    return ListTile(
      key: const Key('dictionary_packs_import'),
      leading: const Icon(Icons.file_open_outlined),
      title: Text(l10n.offlineImportAction),
      subtitle: Text(
        importing
            ? l10n.offlineImporting
            : l10n.offlineDictionariesImportSubtitle,
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
          : () => unawaited(
              context.read<DictionaryPacksCubit>().importFromFiles(),
            ),
    );
  }
}

class _Overview extends StatelessWidget {
  const new({required this.state});

  final DictionaryPacksState state;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final secondary = theme.textTheme.bodyMedium?.copyWith(
      color: palette.secondaryText,
    );
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
          child: Text(l10n.offlineDictionariesDescription, style: secondary),
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
                child: Text(l10n.offlineDictionariesSource, style: secondary),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 36, top: 4),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              key: const Key('dictionary_packs_about'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => unawaited(
                showDictionaryAttribution(
                  context,
                  wiktionaryAttribution,
                  text: l10n.offlineDictionariesSource,
                ),
              ),
              child: Text(l10n.offlineDictionariesAbout),
            ),
          ),
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
      key: const Key('dictionary_packs_unavailable'),
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
                  context.l10n.offlineDictionariesUnavailable,
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
  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  late final TextEditingController _controller = TextEditingController(
    text: context.read<DictionaryPacksCubit>().state.query,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _clear() {
    _controller.clear();
    context.read<DictionaryPacksCubit>().search('');
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
      onChanged: context.read<DictionaryPacksCubit>().search,
    );
  }
}

/// "Dictionaries" on the offline languages screen: opens
/// [DictionaryPacksPage]; says how many are downloaded.
class DictionaryPacksEntry extends StatefulWidget {
  const new({required this.packs, super.key});

  final DictionaryPacks packs;

  @override
  State<DictionaryPacksEntry> createState() => _DictionaryPacksEntryState();
}

class _DictionaryPacksEntryState extends State<DictionaryPacksEntry> {
  StreamSubscription<void>? _changes;
  int? _count;

  @override
  void initState() {
    super.initState();
    _changes = widget.packs.changes.listen((_) => _load());
    _load();
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
  }

  void _load() {
    unawaited(
      widget.packs.installed().then(
        (installed) {
          if (mounted) setState(() => _count = installed.length);
        },
        onError: (Object _) {
          // The count is a hint; the page itself reports failures.
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListTile(
      key: const Key('offline_dictionaries'),
      leading: const Icon(Icons.menu_book_outlined),
      title: Text(l10n.offlineDictionariesTitle),
      subtitle: Text(
        l10n.offlineDictionariesEntrySubtitle(_count ?? 0),
        style: TextStyle(color: AppPalette.of(context).secondaryText),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => unawaited(openDictionaryPacks(context, widget.packs)),
    );
  }
}
