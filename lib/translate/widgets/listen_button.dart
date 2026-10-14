import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/speech/speech_service.dart';

/// Reads [text] aloud in [languageCode] with the [SpeechService] of
/// [context]: toggles the clip [id] at normal speed (`SpeechService.toggle`),
/// or with [slow] reads it slowly from the start (`SpeechService.speak`).
/// A failure shows a snack bar.
Future<void> readAloud(
  BuildContext context, {
  required String id,
  required String text,
  required String languageCode,
  bool slow = false,
}) async {
  final speech = context.read<SpeechService>();
  final messenger = ScaffoldMessenger.maybeOf(context);
  final message = context.l10n.translateSpeechError;
  try {
    if (slow) {
      await speech.speak(
        id: id,
        text: text,
        languageCode: languageCode,
        slow: true,
      );
    } else {
      await speech.toggle(id: id, text: text, languageCode: languageCode);
    }
  } on Object {
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Read-aloud toggle backed by [SpeechService]; shows a stop icon while the
/// clip with [id] plays.
///
/// The text can also be read slowly from the start (`SpeechService.speak`
/// with `slow: true`), also while it plays:
///
/// * a long press on the button (touch, stylus): it also shows the tooltip
///   (the label, and that a long press reads slowly), as a long press on
///   an icon button does;
/// * Shift+Enter (or Shift+Space) while the button has keyboard focus
///   (held keys do not start it over and over);
/// * "Listen slowly" in the button's context menu (right click; not in a
///   browser that shows its own context menu);
/// * the "Listen slowly" custom accessibility action of the button
///   (TalkBack / VoiceOver actions menu); TalkBack also announces the long
///   press as "listen slowly".
///
/// The translate screen's "More tools" menu offers the same for the
/// translation, visibly. Failures show the same snack bar as a normal
/// listen ([readAloud]).
class ListenButton extends StatefulWidget {
  const new({
    required this.id,
    required this.text,
    required this.languageCode,
    this.tooltip,
    this.stopTooltip,
    super.key,
  });

  /// Button id passed to [SpeechService.toggle] (`source` / `target`).
  final String id;
  final String text;

  /// Null disables the button (e.g. undetected or custom language).
  final String? languageCode;

  /// Screen-reader label (and first tooltip line) while nothing plays;
  /// "Listen" by default. Several buttons on one screen should say what
  /// they read.
  final String? tooltip;

  /// Screen-reader label (and first tooltip line) while the clip plays;
  /// "Stop" by default.
  final String? stopTooltip;

  @override
  State<ListenButton> createState() => _ListenButtonState();
}

class _ListenButtonState extends State<ListenButton> {
  late final SpeechService _speech = context.read<SpeechService>();
  late final Stream<String?> _speaking = _speech.speaking;
  final _menu = MenuController();

  bool get _enabled =>
      widget.text.trim().isNotEmpty && widget.languageCode != null;

  Future<void> _play({required bool slow}) async {
    final languageCode = widget.languageCode;
    if (languageCode == null) return;
    await readAloud(
      context,
      id: widget.id,
      text: widget.text,
      languageCode: languageCode,
      slow: slow,
    );
  }

  void _toggle() => unawaited(_play(slow: false));

  void _listenSlowly() {
    if (_enabled) unawaited(_play(slow: true));
  }

  /// Whether a right click opens the context menu: not in a browser that
  /// shows its own (the other ways remain).
  static bool get _hasContextMenu => !kIsWeb || !BrowserContextMenu.enabled;

  void _openMenu(TapUpDetails details) =>
      _menu.open(position: details.localPosition);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final enabled = _enabled;
    final slowly = l10n.speechListenSlowly;
    return StreamBuilder<String?>(
      stream: _speaking,
      initialData: _speech.current,
      builder: (context, snapshot) {
        final playing = snapshot.data == widget.id;
        final label = playing
            ? widget.stopTooltip ?? l10n.commonStop
            : widget.tooltip ?? l10n.commonListen;
        // The label is the button's semantics label (via the icons); the
        // tooltip adds the long press for sighted users. The tooltip
        // handles the long press itself (it would lose a touch long press
        // to the button's), so a touch long press shows it as well.
        final button = Tooltip(
          message: enabled ? l10n.translateListenTooltip(label) : label,
          excludeFromSemantics: true,
          // Whatever the theme says: a tap toggles, a long press is slow.
          triggerMode: TooltipTriggerMode.longPress,
          onTriggered: enabled ? _listenSlowly : null,
          child: IconButton(
            isSelected: playing,
            icon: Icon(Icons.volume_up_outlined, semanticLabel: label),
            selectedIcon: Icon(
              Icons.stop_circle_outlined,
              semanticLabel: label,
            ),
            onPressed: enabled ? _toggle : null,
          ),
        );
        if (!enabled) return button;
        // The context menu stays out of the merged button node.
        return MenuAnchor(
          controller: _menu,
          menuChildren: [
            MenuItemButton(
              key: const Key('listen_slowly_menu_item'),
              leadingIcon: const Icon(Icons.slow_motion_video),
              onPressed: _listenSlowly,
              child: Text(slowly),
            ),
          ],
          child: GestureDetector(
            // The menu is offered as the "Listen slowly" action instead.
            excludeFromSemantics: true,
            onSecondaryTapUp: _hasContextMenu ? _openMenu : null,
            child: CallbackShortcuts(
              // A held key does not start the slow reading over and over.
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
      },
    );
  }
}
