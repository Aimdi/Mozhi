import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/image_translate/view/image_translate_page.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/quality_toggle.dart';
import 'package:mozhi/translate/widgets/recent_pairs_sheet.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';

/// Most recent language pairs offered in [TranslateHero].
const translateHeroMaxPairs = 3;

/// Space between [TranslateHero]'s quality chip and the app mark.
const double translateHeroChipGap = 32;

/// The greeting for the time of day of [now]: morning from 5:00, afternoon
/// from 12:00, evening from 18:00 (and through the night).
String translateGreeting(AppLocalizations l10n, DateTime now) =>
    switch (now.hour) {
      >= 5 && < 12 => l10n.translateGreetingMorning,
      >= 12 && < 18 => l10n.translateGreetingAfternoon,
      _ => l10n.translateGreetingEvening,
    };

/// The middle of the empty translate screen (like Kagi Translate's start
/// screen): the quality mode chip ([QualityChip], while Fast and Best
/// engines are set up and [showQualityChip]; the app bar leaves its toggle
/// out meanwhile), the app mark, a greeting for the time of day and chips
/// for the other ways in (Camera: image translation, Document: document
/// translation). Below them, up to [translateHeroMaxPairs] recent
/// language pairs other than the current one (`AppSettings.recentPairs`;
/// one tap applies a pair with `TranslateCubit.applyLanguagePair`) and,
/// on large screens, where the keyboard shortcuts are. Everything comes
/// from local settings: no requests.
///
/// The composer is docked below it (see `TranslateView`); the hero gives
/// way to the translation as soon as the input has focus or text.
class TranslateHero extends StatelessWidget {
  const new({this.showQualityChip = true, super.key});

  /// Whether the quality chip is offered here (else the screen keeps the
  /// toggle in the app bar, e.g. in a window too low for both).
  final bool showQualityChip;

  /// The clock of the greeting (tests pin it).
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = AppPalette.of(context).secondaryText;
    final state = context.watch<TranslateCubit>().state;
    final recent = context.select<SettingsCubit, List<LanguagePair>>(
      (cubit) => cubit.state.recentPairs,
    );
    final pairs = [
      for (final pair in recent)
        if (!isCurrentLanguagePair(pair, state)) pair,
    ].take(translateHeroMaxPairs).toList();
    final wide =
        MediaQuery.sizeOf(context).width >= TranslateLayout.wideBreakpoint;
    final router = GoRouter.maybeOf(context);
    return Padding(
      key: const Key('translate_hero'),
      padding: const EdgeInsets.symmetric(
        horizontal: TranslateLayout.gutter,
        vertical: 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showQualityChip && state.hasQualityModes) ...[
            const QualityChip(),
            const SizedBox(height: translateHeroChipGap),
          ],
          // The app mark (as in the navigation rail); decorative.
          ExcludeSemantics(
            child: Icon(
              Icons.translate_rounded,
              size: 52,
              color: scheme.primary,
            ),
          ),
          const SizedBox(height: 12),
          Semantics(
            header: true,
            child: Text(
              translateGreeting(l10n, clock()),
              key: const Key('translate_greeting'),
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineMedium?.copyWith(
                color: scheme.onSurface,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
                height: 1.15,
              ),
            ),
          ),
          if (router != null) ...[
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                _HeroChip(
                  key: const Key('translate_hero_camera'),
                  icon: Icons.photo_camera_outlined,
                  label: l10n.translateHeroCamera,
                  onPressed: () => unawaited(
                    router.push<void>(ImageTranslatePage.locationFor()),
                  ),
                ),
                _HeroChip(
                  key: const Key('translate_hero_document'),
                  icon: Icons.description_outlined,
                  label: l10n.translateHeroDocument,
                  onPressed: () =>
                      unawaited(router.push<void>(AppRoutes.documents)),
                ),
              ],
            ),
          ],
          if (pairs.isNotEmpty) ...[
            const SizedBox(height: 24),
            Semantics(
              container: true,
              explicitChildNodes: true,
              label: l10n.translateEmptyRecentPairs,
              child: Column(
                children: [
                  ExcludeSemantics(
                    child: Text(
                      l10n.translateEmptyRecentPairs,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.labelLarge?.copyWith(color: muted),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Outlined hairline pills (X topics).
                  TranslatePills(
                    child: Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final (index, pair) in pairs.indexed)
                          ActionChip(
                            key: ValueKey('translate_empty_pair:$index'),
                            avatar: Icon(
                              Icons.history,
                              size: 18,
                              color: scheme.primary,
                            ),
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
            const SizedBox(height: 24),
            Row(
              mainAxisSize: MainAxisSize.min,
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
    );
  }
}

/// A tonal chip of [TranslateHero]: an icon and a short label.
class _HeroChip extends StatelessWidget {
  const new({
    required this.icon,
    required this.label,
    required this.onPressed,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FilledButton.tonalIcon(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: const StadiumBorder(),
        backgroundColor: scheme.secondaryContainer,
        foregroundColor: scheme.onSecondaryContainer,
        textStyle: Theme.of(context).textTheme.labelLarge
            ?.copyWith(fontWeight: FontWeight.w700),
      ),
      onPressed: onPressed,
      icon: Icon(icon, size: 20, color: scheme.primary),
      label: Text(label),
    );
  }
}
