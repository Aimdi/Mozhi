import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';

/// Whether the translate screen's "More" area is open: the tools under the
/// translation (check meaning, insights, romanization, matching phrases,
/// compare), "Refine & learn", the definitions and "Also translate
/// into…". Collapsed by default, so the screen shows one task: languages,
/// input, translation.
///
/// [toggleFocus] is the focus node of the [TranslateMoreToggle] (where the
/// focus goes back to when a panel opened from the area closes while the
/// area is collapsed).
class TranslateMoreController extends ValueNotifier<bool> {
  new({bool expanded = false}) : super(expanded);

  /// Focus node of the toggle.
  final FocusNode toggleFocus = FocusNode(debugLabel: 'translate_more_toggle');

  bool get expanded => value;

  set expanded(bool expanded) => value = expanded;

  /// Opens a closed area and closes an open one.
  void toggle() => value = !value;

  @override
  void dispose() {
    toggleFocus.dispose();
    super.dispose();
  }
}

/// Provides a [TranslateMoreController] to the translate screen (the output
/// card's toggle and the sections below it) and rebuilds its dependents
/// when the area opens or closes.
class TranslateMoreScope extends InheritedNotifier<TranslateMoreController> {
  const new({
    required TranslateMoreController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);

  /// The controller above [context], or null (e.g. an output card on its
  /// own); dependents rebuild when it changes.
  static TranslateMoreController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<TranslateMoreScope>()
      ?.notifier;
}

/// Creates the [TranslateMoreController] of the translate screen and
/// provides it with a [TranslateMoreScope].
///
/// The user's choice (open or closed) is remembered in memory for the
/// session: in the [PageStorage] of the route, so it survives rebuilds,
/// layout changes (phone / two panes) and compare mode, but is not saved.
class TranslateMoreHost extends StatefulWidget {
  const new({required this.child, super.key});

  final Widget child;

  /// [PageStorage] identifier of the remembered choice.
  static const storageId = 'translate_more_expanded';

  @override
  State<TranslateMoreHost> createState() => _TranslateMoreHostState();
}

class _TranslateMoreHostState extends State<TranslateMoreHost> {
  TranslateMoreController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) return;
    final stored = PageStorage.maybeOf(context)
        ?.readState(context, identifier: TranslateMoreHost.storageId);
    _controller = TranslateMoreController(expanded: stored == true)
      ..addListener(_remember);
  }

  void _remember() {
    PageStorage.maybeOf(context)?.writeState(
      context,
      _controller!.expanded,
      identifier: TranslateMoreHost.storageId,
    );
  }

  @override
  void dispose() {
    _controller
      ?..removeListener(_remember)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      TranslateMoreScope(controller: _controller!, child: widget.child);
}

/// The quiet "More" disclosure under the translation's actions: a 48 dp
/// text button whose chevron turns while the area is open; screen readers
/// hear "More" and whether it is expanded.
class TranslateMoreToggle extends StatelessWidget {
  const new({required this.controller, super.key});

  final TranslateMoreController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final expanded = controller.expanded;
        final color = expanded
            ? theme.colorScheme.primary
            : palette.secondaryText;
        return Tooltip(
          message: expanded ? l10n.translateMoreHide : l10n.translateMoreShow,
          excludeFromSemantics: true,
          child: Semantics(
            expanded: expanded,
            child: TextButton(
              key: const Key('translate_more_toggle'),
              focusNode: controller.toggleFocus,
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
                padding: const EdgeInsetsDirectional.only(start: 12, end: 8),
                foregroundColor: color,
                shape: const StadiumBorder(),
              ),
              onPressed: controller.toggle,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    l10n.translateMore,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 2),
                  AnimatedRotation(
                    turns: expanded ? 0.5 : 0,
                    duration: TranslateLayout.motion(context),
                    curve: Curves.easeOutCubic,
                    child: Icon(Icons.expand_more, size: 20, color: color),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
