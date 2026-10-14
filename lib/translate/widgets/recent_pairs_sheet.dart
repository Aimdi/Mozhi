import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

/// Opens [RecentPairsSheet]; picking a pair applies it
/// (`TranslateCubit.applyLanguagePair`).
Future<void> showRecentPairsSheet(BuildContext context) {
  final translate = context.read<TranslateCubit>();
  final settings = context.read<SettingsCubit>();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => MultiBlocProvider(
      providers: [
        BlocProvider.value(value: translate),
        BlocProvider.value(value: settings),
      ],
      child: const RecentPairsSheet(),
    ),
  );
}

/// Display name of [language] in a language pair ("Detect language" for
/// auto).
String translatePairLanguageName(AppLocalizations l10n, Language language) =>
    language.isAuto ? l10n.translateDetectLanguage : language.name;

/// Whether [pair] is the pair in use: same target, and the same source (or,
/// while detecting, the detected language).
bool isCurrentLanguagePair(LanguagePair pair, TranslateState state) {
  if (pair.target != state.target) return false;
  if (pair.source == state.source) return true;
  final detected = state.source.isAuto ? state.result?.detectedSource : null;
  return detected != null &&
      !pair.source.isCustom &&
      LanguageMatcher.normalize(pair.source.code) ==
          LanguageMatcher.normalize(detected);
}

/// The recently used language pairs (`AppSettings.recentPairs`, most recent
/// first). Picking one sets both languages and closes the sheet; pairs with
/// a custom language are disabled while the engine cannot take custom
/// languages, and say so ("Needs an AI model that takes custom
/// languages"). Shows an empty state when there are none, and a button
/// that forgets them otherwise.
class RecentPairsSheet extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final pairs = context.select<SettingsCubit, List<LanguagePair>>(
      (cubit) => cubit.state.recentPairs,
    );
    final state = context.watch<TranslateCubit>().state;

    void pick(LanguagePair pair) {
      final cubit = context.read<TranslateCubit>();
      Navigator.of(context).pop();
      cubit.applyLanguagePair(pair);
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        key: const Key('translate_recent_pairs_sheet'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(24, 0, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      l10n.translateRecentPairsTitle,
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                ),
                if (pairs.isNotEmpty)
                  IconButton(
                    key: const Key('translate_recent_pairs_clear'),
                    tooltip: l10n.translateRecentPairsClear,
                    icon: const Icon(Icons.delete_sweep_outlined),
                    onPressed: context.read<SettingsCubit>().clearRecentPairs,
                  ),
              ],
            ),
          ),
          if (pairs.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
              child: Column(
                key: const Key('translate_recent_pairs_empty'),
                children: [
                  Icon(
                    Icons.history,
                    size: 40,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    l10n.translateRecentPairsEmpty,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            )
          else
            for (final (index, pair) in pairs.indexed)
              _PairTile(
                key: ValueKey('translate_recent_pair_$index'),
                pair: pair,
                current: isCurrentLanguagePair(pair, state),
                enabled:
                    state.supportsCustomLanguages ||
                    !(pair.source.isCustom || pair.target.isCustom),
                onTap: () => pick(pair),
              ),
        ],
      ),
    );
  }
}

class _PairTile extends StatelessWidget {
  const new({
    required this.pair,
    required this.current,
    required this.enabled,
    required this.onTap,
    super.key,
  });

  final LanguagePair pair;
  final bool current;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final source = translatePairLanguageName(l10n, pair.source);
    final target = translatePairLanguageName(l10n, pair.target);
    final spoken = l10n.translateLanguagePairSemantics(source, target);
    return ListTile(
      contentPadding: const EdgeInsetsDirectional.only(start: 24, end: 16),
      minTileHeight: 48,
      enabled: enabled,
      selected: current,
      leading: Icon(
        pair.source.isCustom || pair.target.isCustom
            ? Icons.auto_awesome
            : Icons.translate,
      ),
      title: Text(
        l10n.translateLanguagePair(source, target),
        semanticsLabel: current
            ? l10n.translateLanguagePairCurrent(spoken)
            : spoken,
      ),
      // Says why the pair cannot be picked (also to screen readers, as part
      // of the tile).
      subtitle: enabled ? null : Text(l10n.translateRecentPairsNeedsCustom),
      trailing: current ? const Icon(Icons.check) : null,
      onTap: onTap,
    );
  }
}
