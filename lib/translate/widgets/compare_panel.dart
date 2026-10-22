import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/proofread/models/proofread_diff.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/language_bar.dart'
    show pickTranslateLanguage;
import 'package:mozhi/translate/widgets/language_text.dart';
import 'package:mozhi/translate/widgets/output_card.dart';
import 'package:mozhi/translate/widgets/skeleton.dart';
import 'package:mozhi/translate/widgets/status_announcer.dart';
import 'package:mozhi/translate/widgets/translate_error.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';
import 'package:translation_repository/translation_repository.dart';

/// How many engines a compare run of [state] uses with the configured
/// [compareIds] (`TranslateState.compareEnginesFor`).
int compareEngineCount(TranslateState state, List<String> compareIds) =>
    state.compareEnginesFor(compareIds).length;

/// Engines whose results read the same once white space is ignored.
String _sameTextKey(String text) => text.trim().replaceAll(RegExp(r'\s+'), ' ');

/// One card of the compare panel: the results of `entries` (several when
/// their engines agree), a failed engine, or an engine still running
/// (`pending`).
typedef CompareCardData = ({
  List<CompareEntry> entries,
  TranslationEngine? pending,
});

/// The cards of a compare run, in engine order: the current translation's
/// (`TranslateState.compareBaseline`) first, then one per engine of
/// [engines] (the run's, see `TranslateState.compareEnginesFor`). Engines
/// whose translations are the same share the card of the first of them;
/// a failed engine gets a card of its own; an engine without a result yet
/// gets a placeholder while [comparing].
List<CompareCardData> compareCards({
  required List<CompareEntry> entries,
  required List<TranslationEngine> engines,
  required bool comparing,
  TranslationResult? baseline,
}) {
  final byId = {for (final entry in entries) entry.id: entry};
  final slots = [
    ?baseline?.engineId,
    for (final engine in engines)
      if (engine.id != baseline?.engineId) engine.id,
    for (final entry in entries)
      if (entry.id != baseline?.engineId &&
          engines.every((engine) => engine.id != entry.id))
        entry.id,
  ];
  final groups = <String, List<CompareEntry>>{};
  for (final id in slots) {
    final result = byId[id]?.result;
    if (result == null) continue;
    (groups[_sameTextKey(result.text)] ??= []).add(byId[id]!);
  }
  final shown = <String>{};
  return [
    for (final id in slots)
      if (byId[id] case final entry?)
        if (entry.result case final result?) ...[
          if (shown.add(_sameTextKey(result.text)))
            (entries: groups[_sameTextKey(result.text)]!, pending: null),
        ] else
          (entries: [entry], pending: null)
      else if (comparing)
        for (final engine in engines)
          if (engine.id == id)
            (entries: const <CompareEntry>[], pending: engine),
  ];
}

/// The header of a card for [names]: the engine, or "DeepL and Google
/// agree", "DeepL, Google and DuckDuckGo agree".
String compareCardTitle(AppLocalizations l10n, List<String> names) {
  if (names.length < 2) return names.firstOrNull ?? '';
  if (names.length == 2) {
    return l10n.translateCompareAgreeTwo(names[0], names[1]);
  }
  return l10n.translateCompareAgreeMany(
    names.sublist(0, names.length - 1).join(l10n.translateCompareNameSeparator),
    names.last,
  );
}

/// Compare mode: the engines' translations side by side.
///
/// Choosing Compare starts the run at once (`TranslateCubit.setCompareMode`)
/// with the current translation as the first card ("Current translation").
/// Cards follow the engines' order, not the order the results arrive in
/// ([compareCards]); engines that agree share one card ("DeepL and Google
/// agree"), and the words in which a card differs from the current
/// translation are highlighted. Engines still running show a placeholder
/// with their name. When every engine has answered, screen readers hear how
/// many succeeded.
///
/// The header's "Done" is the one way out of compare mode (it is entered
/// from the tools under a translation); "Compare" shows while there are no
/// results for the input (after an edit, for example).
class ComparePanel extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final compareIds = context.select<SettingsCubit, List<String>>(
      (cubit) => cubit.state.compareEngineIds,
    );
    return BlocBuilder<TranslateCubit, TranslateState>(
      buildWhen: (previous, current) =>
          previous.compareEntries != current.compareEntries ||
          previous.comparing != current.comparing ||
          previous.compareBaseline != current.compareBaseline ||
          previous.engines != current.engines ||
          previous.source != current.source ||
          previous.target != current.target ||
          previous.input.trim().isEmpty != current.input.trim().isEmpty,
      builder: (context, state) {
        final cubit = context.read<TranslateCubit>();
        final entries = state.compareEntries;
        final baseline = state.compareBaseline;
        final cards = compareCards(
          entries: entries,
          engines: state.compareEnginesFor(compareIds),
          comparing: state.comparing,
          baseline: baseline,
        );
        // The engines asked: all but the current translation's, which is
        // not translated again (a failure has no result).
        final asked = entries
            .where((e) => e.result == null || e.result != baseline)
            .toList();
        final finished = !state.comparing && asked.isNotEmpty
            ? l10n.translateCompareFinished(
                asked.where((e) => e.result != null).length,
                asked.length,
              )
            : null;
        final idle = !state.comparing && entries.isEmpty;
        final differs =
            baseline != null &&
            cards.any(
              (card) =>
                  card.entries.isNotEmpty &&
                  card.entries.first.result != null &&
                  !card.entries.any((entry) => entry.result == baseline),
            );
        return StatusAnnouncer(
          message: finished,
          child: Column(
            key: const Key('translate_compare_panel'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        l10n.translateCompareTitle,
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Tooltip(
                    message: l10n.translateCompareModeExit,
                    child: TextButton(
                      key: const Key('translate_compare_toggle'),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(48, 48),
                      ),
                      onPressed: () => cubit.setCompareMode(enabled: false),
                      child: Text(l10n.translateCompareDone),
                    ),
                  ),
                ],
              ),
              if (idle) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    l10n.translateCompareHint,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                // Under the hint, not in the header: the header keeps room
                // for the title and Done at large text sizes.
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: FilledButton.icon(
                      key: const Key('translate_compare_button'),
                      onPressed: state.input.trim().isEmpty
                          ? null
                          : () => unawaited(cubit.runCompare()),
                      icon: const Icon(Icons.compare_arrows),
                      label: Text(l10n.translateCompareButton),
                    ),
                  ),
                ),
              ] else if (differs)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    l10n.translateCompareDiffHint,
                    key: const Key('translate_compare_diff_hint'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppPalette.of(context).secondaryText,
                    ),
                  ),
                ),
              for (final card in cards) ...[
                const SizedBox(height: TranslateLayout.gap),
                if (card.pending case final engine?)
                  _PendingCard(
                    key: ValueKey('compare_pending:${engine.id}'),
                    name: engine.name,
                  )
                else
                  CompareEntryCard(
                    key: ValueKey('compare:${card.entries.first.id}'),
                    entry: card.entries.first,
                    agreeing: card.entries.sublist(1),
                    target: state.target,
                    baseline: baseline,
                    onUse: () => cubit.useCompareEntry(
                      card.entries.firstWhere(
                        (entry) => entry.result == baseline,
                        orElse: () => card.entries.first,
                      ),
                    ),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// One engine's compare result (or error), or the result several engines
/// agree on ([entry] and [agreeing]).
///
/// With a [baseline] (the translation shown before comparing) the card of
/// that translation is marked "Current translation", and the words of
/// another card that are not in it are highlighted.
class CompareEntryCard extends StatelessWidget {
  const new({
    required this.entry,
    required this.onUse,
    this.target,
    this.agreeing = const [],
    this.baseline,
    super.key,
  });

  final CompareEntry entry;
  final VoidCallback onUse;

  /// Language of the translations (text direction and screen-reader voice).
  final Language? target;

  /// Other engines with the same translation as [entry].
  final List<CompareEntry> agreeing;

  /// The translation compared with (`TranslateState.compareBaseline`).
  final TranslationResult? baseline;

  /// Longest text whose differences are highlighted.
  static const maxDiffLength = 5000;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final result = entry.result;
    final all = [entry, ...agreeing];
    final elapsed = agreeing.isEmpty ? result?.elapsed : null;
    final baseline = this.baseline;
    final current = baseline != null && all.any((e) => e.result == baseline);
    final target = this.target;
    final direction =
        (target == null ? null : textDirectionForLanguage(target)) ??
        (result == null ? null : textDirectionForText(result.text));
    final highlight = TextStyle(
      backgroundColor: scheme.tertiaryContainer,
      color: scheme.onTertiaryContainer,
    );
    return TranslateFlatCard(
      look: TranslateCardLook.quote,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      compareCardTitle(l10n, [for (final e in all) e.name]),
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: scheme.primary,
                      ),
                    ),
                  ),
                  if (elapsed != null)
                    Text(
                      l10n.translateSeconds(formatSeconds(elapsed)),
                      semanticsLabel: l10n.translateSecondsSemantics(
                        formatSeconds(elapsed),
                      ),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            if (current)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  l10n.translateCompareCurrent,
                  key: const Key('translate_compare_current'),
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: AppPalette.of(context).secondaryText,
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 12, bottom: 8),
              child: result != null
                  ? SizedBox(
                      width: double.infinity,
                      child: SelectableText.rich(
                        TextSpan(
                          locale: target == null
                              ? null
                              : localeForLanguage(target),
                          children: current || baseline == null
                              ? [TextSpan(text: result.text)]
                              : _differences(
                                  baseline.text,
                                  result.text,
                                  highlight,
                                ),
                        ),
                        textDirection: direction,
                        style: TranslateLayout.textStyle(
                          context,
                          result.text.length,
                        ),
                      ),
                    )
                  : TranslateErrorView(
                      error: entry.error,
                      dense: true,
                      // Only consent prompts offer it (compare again).
                      onRetry: entry.error is ConsentRequiredException
                          ? () => unawaited(
                              context.read<TranslateCubit>().runCompare(),
                            )
                          : null,
                      // The engine could not detect the input's language:
                      // picking it compares again.
                      onChooseSourceLanguage: () => unawaited(
                        pickTranslateLanguage(context, source: true),
                      ),
                    ),
            ),
            if (result != null)
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IconButton(
                    tooltip: l10n.commonCopy,
                    icon: const Icon(Icons.copy_outlined),
                    onPressed: () =>
                        unawaited(copyToClipboard(context, result.text)),
                  ),
                  TextButton(
                    onPressed: onUse,
                    child: Text(l10n.translateUseThis),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  /// [text] with the words that are not in [baseline] in [highlight]
  /// (a word diff, as in Proofread); plain for long texts.
  static List<TextSpan> _differences(
    String baseline,
    String text,
    TextStyle highlight,
  ) {
    if (text.length > maxDiffLength || baseline.length > maxDiffLength) {
      return [TextSpan(text: text)];
    }
    return [
      for (final segment in ProofreadDiff.wordDiff(baseline, text))
        if (segment.type != DiffType.removed)
          TextSpan(
            text: segment.text,
            style:
                segment.type == DiffType.inserted &&
                    segment.text.trim().isNotEmpty
                ? highlight
                : null,
          ),
    ];
  }
}

/// The place of an engine that is still translating: its [name] over a
/// loading placeholder.
class _PendingCard extends StatelessWidget {
  const new({required this.name, super.key});

  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return TranslateFlatCard(
      look: TranslateCardLook.quote,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              name,
              style: theme.textTheme.titleSmall?.copyWith(
                color: AppPalette.of(context).secondaryText,
              ),
            ),
            const SizedBox(height: 16),
            const SkeletonBox(),
            const SizedBox(height: 8),
            const FractionallySizedBox(widthFactor: 0.6, child: SkeletonBox()),
          ],
        ),
      ),
    );
  }
}
