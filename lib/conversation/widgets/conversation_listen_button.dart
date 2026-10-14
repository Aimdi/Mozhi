import 'package:flutter/foundation.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';

/// Read-aloud toggle of a conversation message; shows a stop icon while
/// [playing].
///
/// Like the translate screen's listen button, the translation can also be
/// read slowly from the start ([onListenSlowly]), also while it plays:
///
/// * a long press (touch, stylus), which also shows the tooltip;
/// * Shift+Enter (or Shift+Space) while the button has keyboard focus
///   (held keys do not start it over and over);
/// * "Listen slowly" in the button's context menu (right click; not in a
///   browser that shows its own context menu);
/// * the "Listen slowly" custom accessibility action.
class ConversationListenButton extends StatefulWidget {
  const new({
    required this.playing,
    required this.onListen,
    required this.onListenSlowly,
    this.color,
    this.buttonKey,
    super.key,
  });

  /// Whether the message is being read aloud.
  final bool playing;

  /// Toggles reading aloud at normal speed; null disables the button.
  final VoidCallback? onListen;

  /// Reads the message slowly from the start; null offers no slow replay.
  final VoidCallback? onListenSlowly;

  /// Icon color.
  final Color? color;

  /// Key of the inner [IconButton].
  final Key? buttonKey;

  @override
  State<ConversationListenButton> createState() =>
      _ConversationListenButtonState();
}

class _ConversationListenButtonState extends State<ConversationListenButton> {
  final _menu = MenuController();

  /// Whether a right click opens the context menu: not in a browser that
  /// shows its own (the other ways remain).
  static bool get _hasContextMenu => !kIsWeb || !BrowserContextMenu.enabled;

  void _listenSlowly() => widget.onListenSlowly?.call();

  void _openMenu(TapUpDetails details) =>
      _menu.open(position: details.localPosition);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final slowEnabled = widget.onListenSlowly != null;
    final slowly = l10n.speechListenSlowly;
    final label = widget.playing ? l10n.commonStop : l10n.commonListen;
    final button = Tooltip(
      message: slowEnabled ? l10n.translateListenTooltip(label) : label,
      excludeFromSemantics: true,
      triggerMode: TooltipTriggerMode.longPress,
      onTriggered: slowEnabled ? _listenSlowly : null,
      child: IconButton(
        key: widget.buttonKey,
        isSelected: widget.playing,
        color: widget.color,
        icon: Icon(Icons.volume_up_outlined, semanticLabel: label),
        selectedIcon: Icon(Icons.stop_circle_outlined, semanticLabel: label),
        onPressed: widget.onListen,
      ),
    );
    if (!slowEnabled) return button;
    return MenuAnchor(
      controller: _menu,
      menuChildren: [
        MenuItemButton(
          key: const Key('conversation_listen_slowly_menu_item'),
          leadingIcon: const Icon(Icons.slow_motion_video),
          onPressed: _listenSlowly,
          child: Text(slowly),
        ),
      ],
      child: GestureDetector(
        excludeFromSemantics: true,
        onSecondaryTapUp: _hasContextMenu ? _openMenu : null,
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(
              LogicalKeyboardKey.enter,
              shift: true,
              includeRepeats: false,
            ): _listenSlowly,
            const SingleActivator(
              LogicalKeyboardKey.numpadEnter,
              shift: true,
              includeRepeats: false,
            ): _listenSlowly,
            const SingleActivator(
              LogicalKeyboardKey.space,
              shift: true,
              includeRepeats: false,
            ): _listenSlowly,
          },
          child: MergeSemantics(
            child: Semantics(
              customSemanticsActions: {
                CustomSemanticsAction(label: slowly): _listenSlowly,
              },
              onLongPress: _listenSlowly,
              onLongPressHint: slowly,
              child: button,
            ),
          ),
        ),
      ),
    );
  }
}
