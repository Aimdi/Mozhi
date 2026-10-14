import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/status_announcer.dart';
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

/// [text] as a bidirectional isolate (FIRST STRONG ISOLATE … POP
/// DIRECTIONAL ISOLATE): it takes the direction of its own first strong
/// character and does not affect the order of the text around it.
String bidiIsolate(String text) => '\u2068$text\u2069';

/// "{source} → {target}" for [pair], laid out in the UI direction.
///
/// The names are isolated ([bidiIsolate]): language names are usually in
/// another script than a right-to-left UI language, and without isolation
/// two left-to-right names around the arrow would be laid out left to
/// right, so the arrow would point from the target to the source.
String translatePairLabel(AppLocalizations l10n, LanguagePair pair) =>
    l10n.translateLanguagePair(
      bidiIsolate(translatePairLanguageName(l10n, pair.source)),
      bidiIsolate(translatePairLanguageName(l10n, pair.target)),
    );

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
/// languages, and say so ("Needs an AI model that supports custom
/// languages"). Shows an empty state when there are none, and a button
/// that forgets them otherwise.
///
/// Clearing is announced ("Recent language pairs cleared") and can be
/// undone as long as the sheet is open: the sheet then says so and offers
/// Undo, which gets the keyboard focus (the clear button is gone); undoing
/// brings the pairs back (after any recorded meanwhile) and the focus to
/// the clear button.
class RecentPairsSheet extends StatefulWidget {
  const new({super.key});

  @override
  State<RecentPairsSheet> createState() => _RecentPairsSheetState();
}

class _RecentPairsSheetState extends State<RecentPairsSheet> {
  final _clearFocus = FocusNode(debugLabel: 'translate_recent_pairs_clear');
  final _undoFocus = FocusNode(debugLabel: 'translate_recent_pairs_undo');

  /// The pairs the clear button forgot, until they are restored.
  List<LanguagePair>? _cleared;

  /// How often the pairs were cleared (each clear is announced).
  int _clears = 0;

  @override
  void dispose() {
    _clearFocus.dispose();
    _undoFocus.dispose();
    super.dispose();
  }

  void _clear(List<LanguagePair> pairs) {
    context.read<SettingsCubit>().clearRecentPairs();
    final earlier = _cleared ?? const [];
    setState(() {
      _clears++;
      _cleared = [...pairs, ...earlier.where((p) => !pairs.contains(p))];
    });
    // The focused button is gone: move the focus to Undo.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _cleared != null) _undoFocus.requestFocus();
    });
  }

  void _undo() {
    final previous = _cleared;
    if (previous == null) return;
    // Pairs recorded meanwhile stay first.
    context.read<SettingsCubit>().update(
      (current) => current.copyWith(
        recentPairs: List.unmodifiable(
          [
            ...current.recentPairs,
            ...previous.where((p) => !current.recentPairs.contains(p)),
          ].take(SettingsCubit.maxRecentPairs),
        ),
      ),
    );
    setState(() => _cleared = null);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _clearFocus.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final pairs = context.select<SettingsCubit, List<LanguagePair>>(
      (cubit) => cubit.state.recentPairs,
    );
    final state = context.watch<TranslateCubit>().state;
    final cleared = _cleared != null;

    void pick(LanguagePair pair) {
      final cubit = context.read<TranslateCubit>();
      Navigator.of(context).pop();
      cubit.applyLanguagePair(pair);
    }

    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return StatusAnnouncer(
      message: cleared ? l10n.settingsRecentPairsCleared : null,
      announcementId: _clears,
      child: SingleChildScrollView(
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
                      focusNode: _clearFocus,
                      tooltip: l10n.translateRecentPairsClear,
                      icon: const Icon(Icons.delete_sweep_outlined),
                      onPressed: () => _clear(pairs),
                    ),
                ],
              ),
            ),
            if (cleared)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
                child: Column(
                  key: const Key('translate_recent_pairs_cleared'),
                  children: [
                    Text(
                      l10n.settingsRecentPairsCleared,
                      textAlign: TextAlign.center,
                      style: muted,
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      key: const Key('translate_recent_pairs_undo'),
                      focusNode: _undoFocus,
                      onPressed: _undo,
                      child: Text(l10n.commonUndo),
                    ),
                  ],
                ),
              ),
            if (pairs.isEmpty && !cleared)
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
                      style: muted,
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
    final target = translatePairLanguageName(l10n, pair.target);
    // Not "From Detect language to …" while the source is detected.
    final spoken = pair.source.isAuto
        ? l10n.translateLanguagePairAutoSemantics(target)
        : l10n.translateLanguagePairSemantics(pair.source.name, target);
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
        translatePairLabel(l10n, pair),
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
