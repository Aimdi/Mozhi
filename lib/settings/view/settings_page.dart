import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/app/view/top_level_actions.dart';
import 'package:mozhi/core/widgets/fold_aware_split.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/models/settings_category.dart';
import 'package:mozhi/settings/view/about_page.dart' show AboutView;
import 'package:mozhi/settings/view/categories/ai_settings.dart';
import 'package:mozhi/settings/view/categories/appearance_settings.dart';
import 'package:mozhi/settings/view/categories/backup_settings.dart';
import 'package:mozhi/settings/view/categories/engine_settings.dart';
import 'package:mozhi/settings/view/categories/general_settings.dart';
import 'package:mozhi/settings/view/categories/speech_settings.dart';
import 'package:mozhi/settings/view/settings_category_labels.dart';
import 'package:mozhi/settings/view/settings_search_index.dart';
import 'package:mozhi/settings/view/widgets/privacy_settings_section.dart';
import 'package:mozhi/settings/view/widgets/search_highlight.dart';
import 'package:mozhi/settings/view/widgets/settings_search.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';

export '../models/settings_category.dart';
export 'widgets/privacy_settings_section.dart' show historyRetentionLabel;

/// The settings (`/settings`): a search field and the list of categories
/// ([SettingsCategory]: General, Privacy & data, Backup & sync, Translation
/// engines, AI, Appearance, Read aloud & voice, About), each opening its page
/// ([SettingsCategoryPage]); on wide screens the same list beside the
/// selected category ([SettingsView]).
///
/// Reads [SettingsCubit] (and `HistoryCubit` for the history rows) from the
/// app-wide providers.
///
/// A full page above the tabs, opened from their app bars
/// ([TopLevelActions]): its back arrow returns to the tab
/// ([topLevelBackButton]).
class SettingsPage extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) => const SettingsView();
}

/// The page of one settings [category] (`/settings/<category>`), scrolled
/// to the row [highlight] names, if any (a search result, or a link with
/// `?row=`). On wide screens the category list stays beside it.
class SettingsCategoryPage extends StatelessWidget {
  const new({required this.category, this.highlight, super.key});

  final SettingsCategory category;

  /// The [SettingsAnchor] to scroll to and highlight.
  final String? highlight;

  @override
  Widget build(BuildContext context) =>
      SettingsView(category: category, highlight: highlight);
}

/// The settings with the [category] page open (null: the list of
/// categories).
///
/// Narrower than [twoPaneBreakpoint] (and not in book posture) it shows
/// either the search field and the categories, or the [category]'s page.
/// Wider, it shows both: the list (master) and the selected category
/// (detail), each its own focus traversal group and semantics container;
/// picking a category there changes the detail, not the location.
///
/// The search field filters every row of every category (titles,
/// subtitles and the names of their choices, [settingsSearchIndex]); a
/// result opens its category scrolled to the row, which is highlighted for
/// a moment ([SettingsAnchor]).
class SettingsView extends StatefulWidget {
  const new({this.category, this.highlight, super.key});

  /// The category whose page this is; null for the settings root.
  final SettingsCategory? category;

  /// The [SettingsAnchor] to scroll to and highlight.
  final String? highlight;

  /// Width from which the categories and the selected one are shown side
  /// by side (also at any width on either side of a vertical hinge or
  /// half-opened fold).
  static const twoPaneBreakpoint = 840.0;

  /// Width of the category list beside the selected category.
  static const masterWidth = 360.0;

  /// Whether on-device (offline) translation can run on this platform:
  /// Mozilla's Bergamot engine is in every build, but not on the web.
  static bool get offlineSupported => EngineSettings.offlineSupported;

  /// Key of the side-by-side layout.
  static const columnsKey = Key('settings_columns');

  /// Key of a category's row in the list.
  static Key categoryKey(SettingsCategory category) =>
      Key('settings_category_${category.path}');

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  final _search = TextEditingController();

  /// The category shown beside the list on wide screens.
  late SettingsCategory _selected = widget.category ?? SettingsCategory.general;

  /// The row to scroll to and highlight.
  late SettingsJump? _jump = switch (widget.highlight) {
    final anchor? => SettingsJump(anchor),
    null => null,
  };
  int _serial = 0;

  @override
  void didUpdateWidget(SettingsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final category = widget.category;
    if (category != null && category != oldWidget.category) {
      _selected = category;
    }
    final highlight = widget.highlight;
    if (highlight != null && highlight != oldWidget.highlight) {
      _jump = SettingsJump(highlight, serial: ++_serial);
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Opens [category] (scrolled to [anchor]): beside the list on wide
  /// screens, as a page of its own otherwise.
  void _open(SettingsCategory category, {required bool wide, String? anchor}) {
    if (wide) {
      setState(() {
        _selected = category;
        _jump = anchor == null ? null : SettingsJump(anchor, serial: ++_serial);
      });
      return;
    }
    unawaited(context.push(category.location(row: anchor)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final settings = context.watch<SettingsCubit>().state;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final bookPosture =
            FoldAwareSplit.featureDirectionOf(context) == Axis.horizontal;
        final wide = width >= SettingsView.twoPaneBreakpoint || bookPosture;
        final category = widget.category;
        final Widget body;
        if (wide) {
          body = _split(settings, bookPosture: bookPosture);
        } else if (category == null) {
          body = _master(settings, wide: false, width: width);
        } else {
          body = _detail(category, settings, wide: false, width: width);
        }
        return Scaffold(
          appBar: AppBar(
            leading: category == null ? topLevelBackButton(context) : null,
            title: wide || category == null
                ? Text(l10n.settingsTitle)
                : _CategoryTitle(category: category),
          ),
          body: body,
        );
      },
    );
  }

  /// The list and the selected category side by side.
  Widget _split(AppSettings settings, {required bool bookPosture}) {
    // Each pane is its own focus traversal group and semantics container,
    // so keyboard and screen-reader order finish the list before moving to
    // the category instead of zig-zagging between them.
    Widget pane(Widget child) => Semantics(
      container: true,
      explicitChildNodes: true,
      child: FocusTraversalGroup(child: child),
    );
    final master = pane(
      _master(settings, wide: true, width: SettingsView.masterWidth),
    );
    final detail = pane(
      LayoutBuilder(
        builder: (context, constraints) => _detail(
          _selected,
          settings,
          wide: true,
          width: constraints.maxWidth,
        ),
      ),
    );
    if (bookPosture) {
      // The panes split at the hinge or fold.
      return FoldAwareSplit(
        key: SettingsView.columnsKey,
        foldDirections: const {Axis.horizontal},
        first: master,
        second: detail,
      );
    }
    return Row(
      key: SettingsView.columnsKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: SettingsView.masterWidth, child: master),
        const Hairline(vertical: true),
        Expanded(child: detail),
      ],
    );
  }

  /// The search field and the categories, or the search results.
  Widget _master(
    AppSettings settings, {
    required bool wide,
    required double width,
  }) {
    final l10n = context.l10n;
    final query = _search.text.trim();
    final results = query.isEmpty
        ? const <SettingsSearchEntry>[]
        : searchSettings(settingsSearchIndex(context, settings), query);
    final categories = [
      for (final category in SettingsCategory.values)
        if (category != SettingsCategory.speech ||
            SpeechCategorySettings.available(context))
          category,
    ];
    return ListView(
      key: const PageStorageKey('settings_master'),
      padding: wide
          ? const EdgeInsets.fromLTRB(12, 8, 12, 32)
          : centeredPadding(width),
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(wide ? 4 : 0, 8, wide ? 4 : 0, 8),
          child: SettingsSearchField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {
              if (results.isEmpty) return;
              final first = results.first;
              _open(first.category, wide: wide, anchor: first.anchor);
            },
          ),
        ),
        if (query.isEmpty)
          for (final category in categories)
            _CategoryTile(
              category: category,
              wide: wide,
              selected: wide && category == _selected,
              onTap: () => _open(category, wide: wide),
            )
        else ...[
          // Results change as the user types: say how many (WCAG 4.1.3).
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 16, 4),
            child: Semantics(
              liveRegion: true,
              child: Text(
                results.isEmpty
                    ? l10n.settingsSearchNoResults(query)
                    : l10n.settingsSearchResults(results.length),
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: AppPalette.of(context).secondaryText),
              ),
            ),
          ),
          for (final entry in results)
            _SearchResultTile(
              entry: entry,
              query: query,
              selected:
                  wide &&
                  entry.category == _selected &&
                  entry.anchor == _jump?.anchor,
              onTap: () =>
                  _open(entry.category, wide: wide, anchor: entry.anchor),
            ),
        ],
      ],
    );
  }

  /// The page of [category]: on wide screens under its heading.
  Widget _detail(
    SettingsCategory category,
    AppSettings settings, {
    required bool wide,
    required double width,
  }) {
    return SingleChildScrollView(
      key: PageStorageKey(category),
      padding: centeredPadding(width),
      child: SettingsJumpScope(
        jump: _jump,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (wide) _CategoryHeading(category: category),
            settingsCategoryContent(category, settings),
          ],
        ),
      ),
    );
  }
}

/// The rows of [category]'s page.
Widget settingsCategoryContent(
  SettingsCategory category,
  AppSettings settings,
) => switch (category) {
  SettingsCategory.general => GeneralSettings(settings: settings),
  SettingsCategory.privacy => PrivacySettingsSection(settings: settings),
  SettingsCategory.backup => BackupSettings(settings: settings),
  SettingsCategory.engines => EngineSettings(settings: settings),
  SettingsCategory.ai => AiSettings(settings: settings),
  SettingsCategory.appearance => AppearanceSettings(settings: settings),
  SettingsCategory.speech => SpeechCategorySettings(settings: settings),
  SettingsCategory.about => const AboutView(),
};

/// The app bar title of a category's page, with its badge.
class _CategoryTitle extends StatelessWidget {
  const new({required this.category});

  final SettingsCategory category;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final badge = category.badge(l10n);
    final title = Text(category.title(l10n));
    if (badge == null) return title;
    return Row(
      children: [
        Flexible(child: title),
        const SizedBox(width: 12),
        StatusBadge(
          label: badge,
          color: Theme.of(context).colorScheme.tertiary,
        ),
      ],
    );
  }
}

/// The selected category's heading beside the list (wide screens, where
/// the app bar says "Settings").
class _CategoryHeading extends StatelessWidget {
  const new({required this.category});

  final SettingsCategory category;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final badge = category.badge(l10n);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 16, 16, 0),
      child: Semantics(
        container: true,
        header: true,
        child: Wrap(
          spacing: 12,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              category.title(l10n),
              style: theme.textTheme.headlineSmall?.copyWith(
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w800,
              ),
            ),
            if (badge != null)
              StatusBadge(label: badge, color: theme.colorScheme.tertiary),
          ],
        ),
      ),
    );
  }
}

/// A category in the list: its icon, title (and badge) and summary.
class _CategoryTile extends StatelessWidget {
  const new({
    required this.category,
    required this.wide,
    required this.selected,
    required this.onTap,
  });

  final SettingsCategory category;
  final bool wide;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final badge = category.badge(l10n);
    final title = Text(category.title(l10n));
    return ListTile(
      key: SettingsView.categoryKey(category),
      leading: SettingsIcon(category.icon),
      title: badge == null
          ? title
          : Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                title,
                StatusBadge(label: badge, color: theme.colorScheme.tertiary),
              ],
            ),
      subtitle: Text(category.summary(l10n)),
      trailing: wide ? null : const Icon(Icons.chevron_right),
      selected: selected,
      selectedTileColor: theme.colorScheme.primary.withValues(alpha: 0.08),
      shape: wide
          ? const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(AppRadius.badge)),
            )
          : null,
      onTap: onTap,
    );
  }
}

/// A search result: the row's title with the match highlighted, and where
/// it is (the category, and the row's subtitle when the match is there).
class _SearchResultTile extends StatelessWidget {
  const new({
    required this.entry,
    required this.query,
    required this.selected,
    required this.onTap,
  });

  final SettingsSearchEntry entry;
  final String query;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final highlight = searchHighlightStyle(context);
    final subtitle = entry.subtitle;
    final showSubtitle =
        subtitle != null && matchRanges(subtitle, query).isNotEmpty;
    return ListTile(
      key: Key('settings_result_${entry.anchor}'),
      leading: SettingsIcon(entry.category.icon),
      title: Text.rich(
        highlightedSpan(entry.title, query, highlight: highlight),
      ),
      subtitle: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: entry.category.title(l10n)),
            if (showSubtitle) ...[
              const TextSpan(text: '\n'),
              highlightedSpan(subtitle, query, highlight: highlight),
            ],
          ],
        ),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      selected: selected,
      onTap: onTap,
    );
  }
}
