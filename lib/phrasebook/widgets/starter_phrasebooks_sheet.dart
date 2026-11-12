import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/data/mirror_hosting.dart';
import 'package:mozhi/offline/widgets/mirror_hosting_banner.dart';
import 'package:mozhi/phrasebook/cubit/starter_phrasebooks_cubit.dart';
import 'package:mozhi/phrasebook/data/phrasebook_repository.dart';
import 'package:mozhi/settings/view/widgets/delete_local_data.dart'
    show formatStoredSize;
import 'package:mozhi/settings/view/widgets/link_launcher.dart';

/// Wikivoyage's credit for its phrasebooks (before one is open).
final Uri wikivoyageUrl = Uri.parse('https://www.wikivoyage.org/');

/// The licence of Wikivoyage's text.
final Uri ccBySa4Url = Uri.parse(
  'https://creativecommons.org/licenses/by-sa/4.0/',
);

/// Shows the starter phrasebooks of [packs]: the catalogue's, each named
/// by its languages ("English ↔ Arabic"), with their sizes, Download
/// (once; checked against the catalogue's SHA-256), Update and Delete, and
/// Wikivoyage's credit. The phrasebooks of the app's own language are left
/// out unless installed ([StarterPhrasebooksState.itemsFor]). Says so
/// gracefully while the catalogue is empty (until the first release of
/// the data). Where the web app cannot download them
/// ([MirrorHostingBuilder]: its server does not host them, or the
/// original publisher refuses web pages), says so once
/// ([MirrorNotHostedBanner]) and offers no Download or Update.
Future<void> showStarterPhrasebooks(
  BuildContext context,
  StarterPhrasebooks packs,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (_) => BlocProvider(
    create: (_) {
      final cubit = StarterPhrasebooksCubit(packs);
      unawaited(cubit.load());
      return cubit;
    },
    child: const StarterPhrasebooksView(),
  ),
);

/// The list of [showStarterPhrasebooks].
class StarterPhrasebooksView extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) =>
      MirrorHostingBuilder(kind: MirrorDataKind.phrasebook, builder: _build);

  Widget _build(BuildContext context, {required bool blocked}) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = AppPalette.of(context).secondaryText;
    final state = context.watch<StarterPhrasebooksCubit>().state;
    final items = state.itemsFor(context.languageNamesLocale);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.4,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Semantics(
              header: true,
              child: Text(
                l10n.phrasebookStarterTitle,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              l10n.phrasebookStarterIntro,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          if (state.loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (items.isEmpty)
            Padding(
              key: const Key('phrasebook_starter_empty'),
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.schedule_outlined, color: muted),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      l10n.phrasebookStarterEmpty,
                      style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                    ),
                  ),
                ],
              ),
            )
          else ...[
            if (blocked) const MirrorNotHostedBanner(),
            for (final item in items)
              _StarterTile(item: item, canDownload: !blocked),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            child: Text(
              l10n.phrasebookStarterSource,
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                  key: const Key('phrasebook_starter_source'),
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () =>
                      unawaited(LinkLauncher.open(context, wikivoyageUrl)),
                  icon: const Icon(Icons.travel_explore_outlined, size: 18),
                  label: Text(l10n.phrasebookStarterCredit),
                ),
                TextButton(
                  key: const Key('phrasebook_starter_license'),
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () =>
                      unawaited(LinkLauncher.open(context, ccBySa4Url)),
                  child: Text(l10n.dictionaryAttributionLicense),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StarterTile extends StatelessWidget {
  const new({required this.item, required this.canDownload});

  final StarterPhrasebookItem item;

  /// False: the web app cannot download it here (no Download or Update;
  /// Delete still works).
  final bool canDownload;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final cubit = context.read<StarterPhrasebooksCubit>();
    final info = item.info;
    final progress = item.progress;
    final error = item.error;
    final details = l10n.phrasebookStarterDetails(
      info.phrases,
      formatStoredSize(l10n, info.size),
    );
    final status = progress != null
        ? l10n.phrasebookStarterDownloading
        : item.isInstalled
        ? l10n.phrasebookStarterInstalled
        : null;
    final Widget trailing;
    if (progress != null) {
      trailing = SizedBox.square(
        dimension: 24,
        child: CircularProgressIndicator(
          value: progress > 0 ? progress : null,
          semanticsLabel: l10n.phrasebookStarterDownloading,
        ),
      );
    } else if (item.isInstalled) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (item.hasUpdate && canDownload)
            TextButton(
              key: ValueKey('phrasebook_starter_update_${info.id}'),
              onPressed: () => unawaited(cubit.install(info)),
              child: Text(l10n.phrasebookStarterUpdate),
            ),
          IconButton(
            key: ValueKey('phrasebook_starter_delete_${info.id}'),
            tooltip: l10n.phrasebookStarterDelete,
            icon: const Icon(Icons.delete_outline),
            onPressed: () => unawaited(cubit.delete(info.id)),
          ),
        ],
      );
    } else {
      trailing = FilledButton.tonal(
        key: ValueKey('phrasebook_starter_download_${info.id}'),
        style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
        onPressed: canDownload ? () => unawaited(cubit.install(info)) : null,
        child: Text(l10n.phrasebookStarterDownload),
      );
    }
    return ListTile(
      key: ValueKey('phrasebook_starter_${info.id}'),
      leading: LanguageAvatar(code: info.language),
      title: Text(
        l10n.phrasebookStarterPair(
          context.languageNameOf(info.baseLanguage),
          switch (context.languageNameOf(info.language)) {
            // A language the app does not know keeps the catalogue's name.
            final name when name == info.language => info.name,
            final name => name,
          },
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text([details, ?status].join(' · ')),
          if (error != null)
            Text(
              switch (error) {
                StarterPhrasebookError.download =>
                  l10n.phrasebookStarterErrorDownload,
                StarterPhrasebookError.server =>
                  l10n.phrasebookStarterErrorServer(item.statusCode ?? 0),
                StarterPhrasebookError.browserRefused =>
                  l10n.phrasebookStarterErrorBrowserRefused,
                StarterPhrasebookError.checksum =>
                  l10n.phrasebookStarterErrorChecksum,
                StarterPhrasebookError.space => switch (item.space) {
                  final space? => space.message(l10n),
                  null => l10n.phrasebookStarterErrorOther,
                },
                StarterPhrasebookError.other =>
                  l10n.phrasebookStarterErrorOther,
              },
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
        ],
      ),
      trailing: trailing,
    );
  }
}
