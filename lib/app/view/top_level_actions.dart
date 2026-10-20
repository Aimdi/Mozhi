import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/core/haptics.dart';
import 'package:mozhi/history/view/history_page.dart'
    show HistoryPage, HistoryTab;
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';

/// History and Settings as app bar icon buttons, shared by the app bars of
/// the four tabs (Translate, Dictionary, Proofread, Conversation).
///
/// Each pushes its page ([AppRoutes.history], [AppRoutes.settings]) above
/// the tabs, so its back arrow returns to the tab it was opened from. Both
/// are 48 dp targets named "History" and "Settings".
///
/// A long press on History opens it on the Favorites tab (quick access to
/// the favourites, like Kagi Translate's star, without another button in
/// a full app bar). Pointing at the button shows that in its tooltip, and
/// TalkBack announces it ("double-tap and hold to open favorites"). The
/// long press vibrates only with haptic feedback on
/// (`AppSettings.hapticFeedback`).
class TopLevelActions extends StatelessWidget {
  const new({super.key});

  /// Key of the History button.
  static const historyKey = Key('top_level_history');

  /// Key of the Settings button.
  static const settingsKey = Key('top_level_settings');

  /// Whether presses give feedback (the long press vibrates): the haptic
  /// feedback setting, rebuilt when it changes ([Haptics.enabled] without
  /// a [SettingsCubit]).
  static bool _feedback(BuildContext context) {
    try {
      return context.select<SettingsCubit, bool>(
        (cubit) => cubit.state.hapticFeedback,
      );
    } on ProviderNotFoundException {
      return Haptics.enabled(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final feedback = _feedback(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The tooltip adds the long press for sighted users; the name stays
        // "History". A touch long press opens the favourites rather than
        // the tooltip (it shows when pointing at the button).
        Tooltip(
          message: l10n.historyButtonTooltip,
          excludeFromSemantics: true,
          triggerMode: TooltipTriggerMode.manual,
          child: MergeSemantics(
            child: Semantics(
              onLongPressHint: l10n.historyOpenFavorites,
              child: IconButton(
                key: historyKey,
                enableFeedback: feedback,
                icon: Icon(Icons.history, semanticLabel: l10n.navHistory),
                onPressed: () =>
                    unawaited(context.push<void>(AppRoutes.history)),
                onLongPress: () => unawaited(
                  context.push<void>(
                    HistoryPage.location(tab: HistoryTab.favorites),
                  ),
                ),
              ),
            ),
          ),
        ),
        IconButton(
          key: settingsKey,
          tooltip: l10n.navSettings,
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => unawaited(context.push<void>(AppRoutes.settings)),
        ),
      ],
    );
  }
}

/// The location of the user's first tab ([AppSettings.tabOrder]), where a
/// page [TopLevelActions] opens goes back to when there is nothing below
/// it; the translate tab without a [SettingsCubit].
String topLevelHomeLocation(BuildContext context) {
  try {
    return AppRoutes.tab(context.read<SettingsCubit>().state.tabOrder.first);
  } on ProviderNotFoundException {
    return AppRoutes.tab(const AppSettings().tabOrder.first);
  }
}

/// The leading back arrow of a page [TopLevelActions] opens (History,
/// Settings).
///
/// Null, the app bar's own back button, while there is a page to go back
/// to (the page was pushed above the tabs) or without a [GoRouter]. When
/// the page is the only one (opened by a link, an app shortcut or a `go`),
/// an arrow that goes to the user's first tab ([topLevelHomeLocation]), so
/// these pages always have a way back.
Widget? topLevelBackButton(BuildContext context) {
  final route = ModalRoute.of(context);
  final router = GoRouter.maybeOf(context);
  if (route == null || route.canPop || router == null) return null;
  return BackButton(
    key: const Key('top_level_back'),
    // Read when pressed: the tab order may have changed in the meantime
    // (Settings > Tab order).
    onPressed: () => router.go(topLevelHomeLocation(context)),
  );
}

/// Wraps a page [TopLevelActions] opens: when it is the only page (opened
/// by a link or an app shortcut), the system back gesture goes to the
/// user's first tab ([topLevelHomeLocation]) instead of leaving the app.
/// Otherwise (or without a [GoRouter]) back works as usual.
class TopLevelPageScope extends StatelessWidget {
  const new({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final router = GoRouter.maybeOf(context);
    final canPop = router == null || (ModalRoute.of(context)?.canPop ?? true);
    return PopScope<Object?>(
      canPop: canPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) router?.go(topLevelHomeLocation(context));
      },
      child: child,
    );
  }
}
