import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
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

/// Adaptive app chrome in the style of X: an icon-only bottom
/// [NavigationBar] on a translucent [BlurBar] for compact/medium widths, and
/// an untinted sidebar ([NavigationRail], collapsed to icons below
/// [AppShell.extendedBreakpoint]) with a hairline edge from
/// [kExpandedBreakpoint] dp.
///
/// The bottom bar hides its labels visually only: each destination keeps
/// its name as its semantic label and tooltip.
class AppShell extends StatelessWidget {
  const new({
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.child,
    super.key,
  });

  /// Width from which the sidebar shows labels.
  static const extendedBreakpoint = 1200.0;

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
        // Pages pad their own last rows for an opaque bar, so content does
        // not scroll under it: no blur needed behind the translucent bar.
        bottomNavigationBar: BlurBar(
          top: true,
          sigma: 0,
          child: NavigationBar(
            selectedIndex: selectedIndex,
            onDestinationSelected: onDestinationSelected,
            destinations: [
              for (final d in destinations)
                NavigationDestination(
                  icon: NavIcon(icon: d.icon, selected: false),
                  selectedIcon: NavIcon(icon: d.selectedIcon, selected: true),
                  label: d.label(l10n),
                ),
            ],
          ),
        ),
      );
    }

    final extended = width >= extendedBreakpoint;
    final theme = Theme.of(context);
    return Scaffold(
      body: Row(
        children: [
          ColoredBox(
            color:
                theme.navigationRailTheme.backgroundColor ??
                theme.colorScheme.surface,
            child: SafeArea(
              right: false,
              child: NavigationRail(
                selectedIndex: selectedIndex,
                onDestinationSelected: onDestinationSelected,
                extended: extended,
                minExtendedWidth: 240,
                labelType: NavigationRailLabelType.none,
                leading: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: _RailHeader(extended: extended),
                ),
                destinations: [
                  for (final d in destinations)
                    NavigationRailDestination(
                      icon: NavIcon(
                        icon: d.icon,
                        selected: false,
                        marker: !extended,
                      ),
                      selectedIcon: NavIcon(
                        icon: d.selectedIcon,
                        selected: true,
                        marker: !extended,
                      ),
                      label: Text(d.label(l10n)),
                    ),
                ],
              ),
            ),
          ),
          const Hairline(vertical: true),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// A navigation icon that cross-fades and scales in (150 ms, instant with
/// reduced motion) when it becomes [selected].
///
/// With [marker], a selected icon also gets a short accent bar beneath it,
/// so selection does not rely on colour alone (WCAG 1.4.1).
class NavIcon extends StatelessWidget {
  const new({
    required this.icon,
    required this.selected,
    this.marker = true,
    super.key,
  });

  final IconData icon;
  final bool selected;
  final bool marker;

  /// Length of the selection transition.
  static const duration = Duration(milliseconds: 150);

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final glyph = Icon(icon);
    final Widget content;
    if (marker) {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          glyph,
          const SizedBox(height: 3),
          SizedBox(
            width: 16,
            height: 3,
            child: selected
                ? DecoratedBox(
                    key: const Key('nav_icon_marker'),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  )
                : null,
          ),
        ],
      );
    } else {
      content = glyph;
    }
    return AnimatedSwitcher(
      duration: reduce ? Duration.zero : duration,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.8, end: 1).animate(animation),
          child: child,
        ),
      ),
      child: KeyedSubtree(key: ValueKey(selected), child: content),
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
      size: 30,
    );
    if (!extended) {
      return Semantics(label: context.l10n.appTitle, child: logo);
    }
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          logo,
          const SizedBox(width: 12),
          Text(
            context.l10n.appTitle,
            style: theme.textTheme.headlineSmall?.copyWith(
              color: theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}
