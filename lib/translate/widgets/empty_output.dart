import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/recent_pairs_sheet.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';

/// Most recent language pairs offered in [EmptyOutput].
const emptyOutputMaxPairs = 3;

/// The output card before there is a translation: what goes here, how to
/// start (type, paste, speak or a photo), up to [emptyOutputMaxPairs]
/// recent language pairs other than the current one
/// (`AppSettings.recentPairs`; one tap applies a pair with
/// `TranslateCubit.applyLanguagePair`) and, on large screens, where the
/// keyboard shortcuts are. Everything comes from local settings: no
/// requests.
class EmptyOutput extends StatelessWidget {
  const new({required this.state, super.key});

  final TranslateState state;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    final recent = context.select<SettingsCubit, List<LanguagePair>>(
      (cubit) => cubit.state.recentPairs,
    );
    final pairs = [
      for (final pair in recent)
        if (!isCurrentLanguagePair(pair, state)) pair,
    ].take(emptyOutputMaxPairs).toList();
    final wide =
        MediaQuery.sizeOf(context).width >= TranslateLayout.wideBreakpoint;
    return ConstrainedBox(
      key: const Key('translate_empty_output'),
      constraints: const BoxConstraints(minHeight: 96),
      child: Padding(
        padding: const EdgeInsetsDirectional.only(top: 8, end: 12, bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.translateEmptyTitle,
              style: theme.textTheme.titleLarge?.copyWith(
                color: muted,
                fontWeight: FontWeight.w400,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              l10n.translateEmptyHint,
              style: theme.textTheme.bodyMedium?.copyWith(color: muted),
            ),
            if (pairs.isNotEmpty) ...[
              const SizedBox(height: 20),
              Semantics(
                container: true,
                explicitChildNodes: true,
                label: l10n.translateEmptyRecentPairs,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ExcludeSemantics(
                      child: Text(
                        l10n.translateEmptyRecentPairs,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: muted,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    // Flat chips paint the canvas colour: let the card's
                    // surface show through.
                    Theme(
                      data: theme.copyWith(canvasColor: Colors.transparent),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final (index, pair) in pairs.indexed)
                            ActionChip(
                              key: ValueKey('translate_empty_pair:$index'),
                              label: Text(translatePairLabel(l10n, pair)),
                              onPressed:
                                  (pair.source.isCustom ||
                                          pair.target.isCustom) &&
                                      !state.supportsCustomLanguages
                                  ? null
                                  : () => context
                                        .read<TranslateCubit>()
                                        .applyLanguagePair(pair),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (wide) ...[
              const SizedBox(height: 20),
              Row(
                children: [
                  Icon(Icons.keyboard_outlined, size: 18, color: muted),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      l10n.translateEmptyShortcutsTip,
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
