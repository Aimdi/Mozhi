import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';

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

  /// Translate, Dictionary, Proofread, Conversation (in branch order).
  ///
  /// History and Settings are not tabs: they are app bar actions of every
  /// tab (`TopLevelActions`) that open full pages above the tabs.
  ///
  /// The destination of an [AppTab] is `all[tab.index]` ([of]).
  static final all = <AppDestination>[
    AppDestination(
      icon: Icons.translate_outlined,
      selectedIcon: Icons.translate,
      label: (l10n) => l10n.navTranslate,
    ),
    AppDestination(
      icon: Icons.menu_book_outlined,
      selectedIcon: Icons.menu_book,
      label: (l10n) => l10n.navDictionary,
    ),
    AppDestination(
      icon: Icons.spellcheck_outlined,
      selectedIcon: Icons.spellcheck,
      label: (l10n) => l10n.navProofread,
    ),
    AppDestination(
      icon: Icons.forum_outlined,
      selectedIcon: Icons.forum,
      label: (l10n) => l10n.navConversation,
    ),
  ];

  /// The destination of [tab].
  static AppDestination of(AppTab tab) => all[tab.index];
}

/// Adaptive app chrome in the style of X: a labelled bottom
/// [NavigationBar] on a translucent [BlurBar] for compact/medium widths, and
/// an untinted sidebar ([NavigationRail]: icons over small labels below
/// [AppShell.extendedBreakpoint], icons beside bold labels from there) with
/// a hairline edge from [kExpandedBreakpoint] dp.
///
/// Keyboard: Tab goes through the sidebar first, then the tab (its app bar,
/// then its content); on phones through the tab, then the bottom bar.
/// [tabShortcuts] (Ctrl+Shift+1 … 4) open the tab at that place of the
/// user's order and [historyShortcut] (Ctrl+Shift+H) opens History, from
/// anywhere in the tabs (also while typing: they type nothing) as long as
/// nothing is open above them. In a browser they leave the key to the
/// browser as well, so its own shortcuts keep working.
///
/// The app is drawn edge to edge (Android 10+), and the shell keeps every
/// tab clear of the system bars below and beside it: the bottom bar and the
/// sidebar avoid them on their side, and the tab ([child]) on the other
/// sides but the top, which its app bar covers. The sidebar follows the
/// text direction (on the right in right-to-left languages).
///
/// The destinations are shown in [order] (by default the user's order,
/// `AppSettings.tabOrder`, from the [SettingsCubit] above, else the
/// default order). [selectedIndex] and [onDestinationSelected] always use
/// the branch indexes ([AppTab.index]), whatever the order on screen.
class AppShell extends StatelessWidget {
  const new({
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.child,
    this.order,
    super.key,
  });

  /// Width from which the sidebar shows its labels beside the icons.
  static const extendedBreakpoint = 1200.0;

  /// Ctrl+Shift+1 … 4: the first … fourth tab of the user's order.
  ///
  /// Not Alt+digit: the translate tab uses that for its pinned languages
  /// and browsers and ChromeOS for their tabs and apps. Not Ctrl+digit:
  /// browsers switch tabs with it.
  static const tabShortcuts = <SingleActivator>[
    SingleActivator(LogicalKeyboardKey.digit1, control: true, shift: true),
    SingleActivator(LogicalKeyboardKey.digit2, control: true, shift: true),
    SingleActivator(LogicalKeyboardKey.digit3, control: true, shift: true),
    SingleActivator(LogicalKeyboardKey.digit4, control: true, shift: true),
  ];

  /// Ctrl+Shift+H: open History ([AppRoutes.history]).
  static const historyShortcut = SingleActivator(
    LogicalKeyboardKey.keyH,
    control: true,
    shift: true,
  );

  /// The branch index ([AppTab.index]) of the active tab.
  final int selectedIndex;

  /// Called with the branch index ([AppTab.index]) of the chosen tab.
  final ValueChanged<int> onDestinationSelected;

  /// The order of the destinations; null: the user's order.
  final List<AppTab>? order;

  /// The active branch.
  final Widget child;

  /// The user's tab order from the [SettingsCubit] above [context] (the
  /// default order without one).
  static List<AppTab> _userOrder(BuildContext context) {
    try {
      return context.select<SettingsCubit, List<AppTab>>(
        (cubit) => cubit.state.tabOrder,
      );
    } on ProviderNotFoundException {
      return AppTab.values;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final width = MediaQuery.sizeOf(context).width;
    final tabs = AppSettings.normalizeTabOrder(order ?? _userOrder(context));
    final destinations = [for (final tab in tabs) AppDestination.of(tab)];
    // Positions on screen <-> branch indexes.
    final selected = tabs.indexWhere((tab) => tab.index == selectedIndex);
    final selectedPosition = selected == -1 ? 0 : selected;
    void select(int position) => onDestinationSelected(tabs[position].index);

    if (width < kExpandedBreakpoint) {
      return _GlobalShortcuts(
        onTab: (position) {
          if (position < tabs.length) select(position);
        },
        child: FocusTraversalGroup(
          policy: OrderedTraversalPolicy(),
          child: Scaffold(
            // The bar keeps clear of the system's navigation bar below; the
            // tab of the one at a side (three-button navigation in
            // landscape).
            body: FocusTraversalOrder(
              order: const NumericFocusOrder(1),
              child: FocusTraversalGroup(
                child: SafeArea(top: false, bottom: false, child: child),
              ),
            ),
            // Pages pad their own last rows for an opaque bar, so content
            // does not scroll under it: no blur needed behind the
            // translucent bar.
            bottomNavigationBar: FocusTraversalOrder(
              order: const NumericFocusOrder(2),
              child: FocusTraversalGroup(
                child: BlurBar(
                  top: true,
                  sigma: 0,
                  child: NavigationBar(
                    selectedIndex: selectedPosition,
                    onDestinationSelected: select,
                    destinations: [
                      for (final d in destinations)
                        NavigationDestination(
                          icon: NavIcon(icon: d.icon, selected: false),
                          selectedIcon: NavIcon(
                            icon: d.selectedIcon,
                            selected: true,
                          ),
                          label: d.label(l10n),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    final extended = width >= extendedBreakpoint;
    final theme = Theme.of(context);
    // Collapsed, small labels under the icons (the theme's bold labels are
    // for the extended sidebar).
    TextStyle? railLabel({required bool selected}) => extended
        ? null
        : theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurface,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
          );
    // The sidebar is at the start: on the right in right-to-left languages.
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return _GlobalShortcuts(
      onTab: (position) {
        if (position < tabs.length) select(position);
      },
      child: FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: Scaffold(
          body: Row(
            children: [
              // Tab goes through the sidebar first, then the tab.
              FocusTraversalOrder(
                order: const NumericFocusOrder(1),
                child: FocusTraversalGroup(
                  child: ColoredBox(
                    color:
                        theme.navigationRailTheme.backgroundColor ??
                        theme.colorScheme.surface,
                    child: SafeArea(
                      left: !rtl,
                      right: rtl,
                      child: NavigationRail(
                        selectedIndex: selectedPosition,
                        onDestinationSelected: select,
                        extended: extended,
                        minExtendedWidth: 240,
                        labelType: extended
                            ? NavigationRailLabelType.none
                            : NavigationRailLabelType.all,
                        selectedLabelTextStyle: railLabel(selected: true),
                        unselectedLabelTextStyle: railLabel(selected: false),
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
                ),
              ),
              const Hairline(vertical: true),
              Expanded(
                // The sidebar keeps clear of its side and the app bars of
                // the top: the tab avoids the system bars below and at the
                // far side (the docked composers, the language bars).
                child: FocusTraversalOrder(
                  order: const NumericFocusOrder(2),
                  child: FocusTraversalGroup(
                    child: MediaQuery.removePadding(
                      context: context,
                      removeLeft: !rtl,
                      removeRight: rtl,
                      child: SafeArea(top: false, child: child),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Handles [AppShell.tabShortcuts] (calls [onTab] with the position) and
/// [AppShell.historyShortcut] while the shell's page is the current route
/// (nothing open above it), wherever focus is, even when nothing has it.
///
/// In a browser the key also goes on to the browser, so a shortcut of its
/// own (e.g. Firefox's Ctrl+Shift+H) still works.
class _GlobalShortcuts extends StatefulWidget {
  const new({required this.onTab, required this.child});

  final ValueChanged<int> onTab;
  final Widget child;

  @override
  State<_GlobalShortcuts> createState() => _GlobalShortcutsState();
}

class _GlobalShortcutsState extends State<_GlobalShortcuts> {
  ModalRoute<Object?>? _route;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent || !mounted) return false;
    if (!(_route?.isCurrent ?? true)) return false;
    final keyboard = HardwareKeyboard.instance;
    for (final (position, shortcut) in AppShell.tabShortcuts.indexed) {
      if (shortcut.accepts(event, keyboard)) {
        widget.onTab(position);
        return !kIsWeb;
      }
    }
    if (AppShell.historyShortcut.accepts(event, keyboard)) {
      final router = GoRouter.maybeOf(context);
      if (router == null) return false;
      unawaited(router.push<void>(AppRoutes.history));
      return !kIsWeb;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
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
