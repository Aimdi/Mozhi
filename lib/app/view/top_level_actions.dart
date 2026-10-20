import 'dart:async';

import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/l10n/l10n.dart';

/// History and Settings as app bar icon buttons, shared by the app bars of
/// the four tabs (Translate, Dictionary, Proofread, Conversation).
///
/// Each pushes its page ([AppRoutes.history], [AppRoutes.settings]) above
/// the tabs, so its back arrow returns to the tab it was opened from. Both
/// are 48 dp targets named by their tooltips.
class TopLevelActions extends StatelessWidget {
  const new({super.key});

  /// Key of the History button.
  static const historyKey = Key('top_level_history');

  /// Key of the Settings button.
  static const settingsKey = Key('top_level_settings');

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: historyKey,
          tooltip: l10n.navHistory,
          icon: const Icon(Icons.history),
          onPressed: () => unawaited(context.push<void>(AppRoutes.history)),
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

/// The leading back arrow of a page [TopLevelActions] opens (History,
/// Settings).
///
/// Null, the app bar's own back button, while there is a page to go back
/// to (the page was pushed above the tabs) or without a [GoRouter]. When
/// the page is the only one (opened by a link, an app shortcut or a `go`),
/// an arrow that goes to the translate tab, so these pages always have a
/// way back.
Widget? topLevelBackButton(BuildContext context) {
  final route = ModalRoute.of(context);
  final router = GoRouter.maybeOf(context);
  if (route == null || route.canPop || router == null) return null;
  return BackButton(
    key: const Key('top_level_back'),
    onPressed: () => router.go(AppRoutes.translate),
  );
}

/// Wraps a page [TopLevelActions] opens: when it is the only page (opened
/// by a link or an app shortcut), the system back gesture goes to the
/// translate tab instead of leaving the app. Otherwise (or without a
/// [GoRouter]) back works as usual.
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
        if (!didPop) router?.go(AppRoutes.translate);
      },
      child: child,
    );
  }
}
