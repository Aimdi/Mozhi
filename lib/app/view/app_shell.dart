import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/l10n/l10n.dart';

/// One top-level destination of the app.
class AppDestination {
  const new({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String Function(AppLocalizations l10n) label;

  /// Translate, Proofread, History, Settings (in branch order).
  static final all = <AppDestination>[
    AppDestination(
      icon: Icons.translate_outlined,
      selectedIcon: Icons.translate,
      label: (l10n) => l10n.navTranslate,
    ),
    AppDestination(
      icon: Icons.spellcheck_outlined,
      selectedIcon: Icons.spellcheck,
      label: (l10n) => l10n.navProofread,
    ),
    AppDestination(
      icon: Icons.history_outlined,
      selectedIcon: Icons.history,
      label: (l10n) => l10n.navHistory,
    ),
    AppDestination(
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings,
      label: (l10n) => l10n.navSettings,
    ),
  ];
}

/// Adaptive app chrome: a bottom [NavigationBar] on compact/medium widths
/// and a [NavigationRail] from [kExpandedBreakpoint] dp.
class AppShell extends StatelessWidget {
  const new({
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.child,
    super.key,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  /// The active branch.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final width = MediaQuery.sizeOf(context).width;
    final destinations = AppDestination.all;

    if (width < kExpandedBreakpoint) {
      return Scaffold(
        body: child,
        bottomNavigationBar: NavigationBar(
          selectedIndex: selectedIndex,
          onDestinationSelected: onDestinationSelected,
          destinations: [
            for (final d in destinations)
              NavigationDestination(
                icon: Icon(d.icon),
                selectedIcon: Icon(d.selectedIcon),
                label: d.label(l10n),
              ),
          ],
        ),
      );
    }

    final extended = width >= 1200;
    final theme = Theme.of(context);
    final railColor =
        theme.navigationRailTheme.backgroundColor ??
        theme.colorScheme.surfaceContainerLow;
    return Scaffold(
      body: Row(
        children: [
          // The tinted rail sets itself apart from the page without a
          // divider; the colour also fills the safe area beside it.
          ColoredBox(
            color: railColor,
            child: SafeArea(
              right: false,
              child: NavigationRail(
                selectedIndex: selectedIndex,
                onDestinationSelected: onDestinationSelected,
                extended: extended,
                minExtendedWidth: 200,
                labelType: extended
                    ? NavigationRailLabelType.none
                    : NavigationRailLabelType.all,
                leading: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: _RailHeader(extended: extended),
                ),
                destinations: [
                  for (final d in destinations)
                    NavigationRailDestination(
                      icon: Icon(d.icon),
                      selectedIcon: Icon(d.selectedIcon),
                      label: Text(d.label(l10n)),
                    ),
                ],
              ),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _RailHeader extends StatelessWidget {
  const new({required this.extended});

  final bool extended;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final logo = Icon(
      Icons.translate_rounded,
      color: theme.colorScheme.primary,
      size: 28,
    );
    if (!extended) {
      return Semantics(label: context.l10n.appTitle, child: logo);
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        logo,
        const SizedBox(width: 12),
        Text(context.l10n.appTitle, style: theme.textTheme.titleLarge),
      ],
    );
  }
}
