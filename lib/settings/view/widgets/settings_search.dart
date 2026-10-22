import 'dart:async';
import 'dart:ui' show SemanticsInputType;

import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/privacy/ime_learning.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/models/settings_category.dart';

/// One searchable settings row: where it is ([category], [anchor]: the id
/// of its [SettingsAnchor]) and what it says ([title], [subtitle]), plus
/// [keywords] that also find it (e.g. the names of its choices).
class SettingsSearchEntry {
  const new({
    required this.category,
    required this.anchor,
    required this.title,
    this.subtitle,
    this.keywords = const [],
  });

  final SettingsCategory category;
  final String anchor;
  final String title;
  final String? subtitle;
  final List<String> keywords;

  /// Whether every word of [query] occurs in the title, the subtitle or a
  /// keyword (ignoring case).
  bool matches(String query) {
    final words = query.toLowerCase().split(RegExp(r'\s+'))
      ..removeWhere((word) => word.isEmpty);
    if (words.isEmpty) return false;
    final haystack = [title, ?subtitle, ...keywords].join('\n').toLowerCase();
    return words.every(haystack.contains);
  }

  /// Whether [query] (as a whole) occurs in the title.
  bool titleMatches(String query) =>
      title.toLowerCase().contains(query.trim().toLowerCase());
}

/// The entries of [entries] that match [query]
/// ([SettingsSearchEntry.matches]): those whose title has the query first,
/// each group in the settings' order.
List<SettingsSearchEntry> searchSettings(
  List<SettingsSearchEntry> entries,
  String query,
) {
  final matching = entries.where((entry) => entry.matches(query)).toList();
  return [
    ...matching.where((entry) => entry.titleMatches(query)),
    ...matching.where((entry) => !entry.titleMatches(query)),
  ];
}

/// A request to scroll to the [SettingsAnchor] [anchor] and highlight it.
/// [serial] tells a repeated jump to the same row from the previous one.
@immutable
class SettingsJump {
  const new(this.anchor, {this.serial = 0});

  final String anchor;
  final int serial;

  @override
  bool operator ==(Object other) =>
      other is SettingsJump && other.anchor == anchor && other.serial == serial;

  @override
  int get hashCode => Object.hash(anchor, serial);
}

/// Hands the current [SettingsJump] to the [SettingsAnchor]s below.
class SettingsJumpScope extends InheritedWidget {
  const new({required this.jump, required super.child, super.key});

  final SettingsJump? jump;

  static SettingsJump? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SettingsJumpScope>()?.jump;

  @override
  bool updateShouldNotify(SettingsJumpScope oldWidget) =>
      jump != oldWidget.jump;
}

/// A settings row a search result (or a `?row=` link) can jump to: when
/// the [SettingsJumpScope]'s jump names [id], it is scrolled into view and
/// highlighted for a moment (without fading under reduced motion).
class SettingsAnchor extends StatefulWidget {
  const new({required this.id, required this.child, super.key});

  final String id;
  final Widget child;

  /// How long a row stays highlighted after a jump.
  static const highlightDuration = Duration(milliseconds: 1600);

  /// The key of the highlight around the row [id].
  static Key highlightKey(String id) => Key('settings_anchor_$id');

  @override
  State<SettingsAnchor> createState() => _SettingsAnchorState();
}

class _SettingsAnchorState extends State<SettingsAnchor> {
  SettingsJump? _handled;
  bool _highlighted = false;
  Timer? _timer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final jump = SettingsJumpScope.of(context);
    if (jump == null || jump.anchor != widget.id || jump == _handled) return;
    _handled = jump;
    _highlighted = true;
    _timer?.cancel();
    _timer = Timer(SettingsAnchor.highlightDuration, () {
      if (mounted) setState(() => _highlighted = false);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final reduceMotion =
          MediaQuery.maybeDisableAnimationsOf(context) ?? false;
      Scrollable.ensureVisible(
        context,
        alignment: 0.2,
        duration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final tint = Theme.of(context).colorScheme.primary.withValues(alpha: 0.14);
    return AnimatedContainer(
      key: SettingsAnchor.highlightKey(widget.id),
      duration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 600),
      foregroundDecoration: BoxDecoration(
        color: _highlighted ? tint : tint.withValues(alpha: 0),
        borderRadius: AppRadius.cardBorderRadius,
      ),
      // Ink splashes stay visible under the highlight.
      child: Material(type: MaterialType.transparency, child: widget.child),
    );
  }
}

/// The settings search field: outlined and rounded like the History
/// search, a search box for screen readers, with keyboard learning off
/// while incognito ([imeLearningAllowed]).
class SettingsSearchField extends StatelessWidget {
  const new({
    required this.controller,
    required this.onChanged,
    this.onSubmitted,
    super.key,
  });

  static const fieldKey = Key('settings_search');

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  /// Called with Enter (e.g. to open the first result).
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    const none = InputBorder.none;
    final outline =
        theme.inputDecorationTheme.enabledBorder?.borderSide.color ??
        colors.outline;
    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.fieldBorderRadius,
        side: BorderSide(color: outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Icon(Icons.search, color: colors.onSurface),
              ),
              Expanded(
                child: Semantics(
                  inputType: SemanticsInputType.search,
                  child: TextField(
                    key: fieldKey,
                    controller: controller,
                    onChanged: onChanged,
                    onSubmitted: onSubmitted,
                    enableIMEPersonalizedLearning: imeLearningAllowed(context),
                    textInputAction: TextInputAction.search,
                    style: theme.textTheme.bodyLarge,
                    decoration: InputDecoration(
                      hintText: l10n.settingsSearchHint,
                      hintStyle: theme.textTheme.bodyLarge?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                      filled: false,
                      border: none,
                      enabledBorder: none,
                      focusedBorder: none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
              ),
              ValueListenableBuilder(
                valueListenable: controller,
                builder: (context, value, _) => value.text.isEmpty
                    ? const SizedBox.shrink()
                    : IconButton(
                        tooltip: l10n.settingsSearchClear,
                        icon: Icon(Icons.close, color: colors.onSurfaceVariant),
                        onPressed: () {
                          controller.clear();
                          onChanged('');
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
