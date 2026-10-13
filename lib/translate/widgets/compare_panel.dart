import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/language_text.dart';
import 'package:mozhi/translate/widgets/output_card.dart';
import 'package:mozhi/translate/widgets/skeleton.dart';
import 'package:mozhi/translate/widgets/status_announcer.dart';
import 'package:mozhi/translate/widgets/translate_error.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';
import 'package:translation_repository/translation_repository.dart';

/// Compare mode: a card per engine result with copy and "Use this", plus
/// placeholders for engines that are still running. When every engine has
/// answered, screen readers hear how many succeeded.
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
          previous.engines != current.engines ||
          previous.input.trim().isEmpty != current.input.trim().isEmpty,
      builder: (context, state) {
        final cubit = context.read<TranslateCubit>();
        final expected = compareIds.isEmpty
            ? state.engines.length
            : state.engines.where((e) => compareIds.contains(e.id)).length;
        final placeholders = state.comparing
            ? math.max(1, expected - state.compareEntries.length)
            : 0;
        final entries = state.compareEntries;
        final finished = !state.comparing && entries.isNotEmpty
            ? l10n.translateCompareFinished(
                entries.where((e) => e.result != null).length,
                entries.length,
              )
            : null;
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
                  FilledButton.icon(
                    key: const Key('translate_compare_button'),
                    onPressed: state.input.trim().isEmpty || state.comparing
                        ? null
                        : () => unawaited(cubit.runCompare()),
                    icon: const Icon(Icons.compare_arrows),
                    label: Text(l10n.translateCompareButton),
                  ),
                ],
              ),
              if (!state.comparing && state.compareEntries.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    l10n.translateCompareHint,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              for (final entry in entries) ...[
                const SizedBox(height: TranslateLayout.gap),
                CompareEntryCard(
                  key: ValueKey('compare:${entry.id}'),
                  entry: entry,
                  target: state.target,
                  onUse: () => cubit.useCompareEntry(entry),
                ),
              ],
              for (var i = 0; i < placeholders; i++) ...[
                const SizedBox(height: TranslateLayout.gap),
                const SkeletonCard(),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// One engine's compare result (or error).
class CompareEntryCard extends StatelessWidget {
  const new({required this.entry, required this.onUse, this.target, super.key});

  final CompareEntry entry;
  final VoidCallback onUse;

  /// Language of the translations (text direction and screen-reader voice).
  final Language? target;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final result = entry.result;
    final elapsed = result?.elapsed;
    final target = this.target;
    final direction =
        (target == null ? null : textDirectionForLanguage(target)) ??
        (result == null ? null : textDirectionForText(result.text));
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: theme.colorScheme.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: TranslateLayout.cardBorderRadius,
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(20, 16, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      entry.name,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.primary,
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
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
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
                          text: result.text,
                          locale: target == null
                              ? null
                              : localeForLanguage(target),
                        ),
                        textDirection: direction,
                        style: TranslateLayout.textStyle(
                          context,
                          result.text.length,
                        ),
                      ),
                    )
                  : TranslateErrorView(error: entry.error, dense: true),
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
}
