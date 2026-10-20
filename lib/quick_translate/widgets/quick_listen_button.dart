import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/haptics.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:translation_repository/translation_repository.dart'
    show ConsentRequiredException;

/// Reads the translation aloud through [SpeechService.toggle]; shows a stop
/// icon while the clip with [id] plays. Playback stops when the button is
/// removed (e.g. the quick translate sheet closes).
///
/// Like the translate screen's listen button, the translation can also be
/// read slowly from the start (`SpeechService.speak` with `slow: true`),
/// also while it plays:
///
/// * a long press (touch, stylus), which also shows the tooltip;
/// * Shift+Enter (or Shift+Space) while the button has keyboard focus
///   (held keys do not start it over and over);
/// * "Listen slowly" in the button's context menu (right click; not in a
///   browser that shows its own context menu);
/// * the "Listen slowly" custom accessibility action.
///
/// Failures call [onError], as a normal listen does, with the error and,
/// when a Mozhi instance could read the text with the user's consent
/// (`SpeechUnavailableException.onlineConsent`), a callback that listens
/// again with that consent.
class QuickListenButton extends StatefulWidget {
  const new({
    required this.speech,
    required this.text,
    required this.languageCode,
    this.id = defaultId,
    this.onError,
    super.key,
  });

  /// Speaking id used by the quick translate sheet.
  static const defaultId = 'quick_translate';

  final SpeechService speech;
  final String text;

  /// Null disables the button (custom target, nothing translated yet).
  final String? languageCode;
  final String id;

  /// Called when the audio could not be fetched or played.
  final void Function(Object error, VoidCallback? listenOnline)? onError;

  @override
  State<QuickListenButton> createState() => _QuickListenButtonState();
}

class _QuickListenButtonState extends State<QuickListenButton> {
  StreamSubscription<String?>? _subscription;
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(QuickListenButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.speech, widget.speech)) {
      unawaited(_subscription?.cancel());
      _playing = false;
      _subscribe();
    }
  }

  void _subscribe() {
    _subscription = widget.speech.speaking.listen((id) {
      final playing = id == widget.id;
      if (mounted && playing != _playing) setState(() => _playing = playing);
    });
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    if (_playing) {
      // Toggling the playing id stops it.
      unawaited(
        widget.speech
            .toggle(id: widget.id, text: widget.text, languageCode: '')
            .catchError((Object _) {}),
      );
    }
    super.dispose();
  }

  final _menu = MenuController();

  bool get _enabled =>
      widget.text.trim().isNotEmpty && widget.languageCode != null;

  Future<void> _toggle({ConsentRequiredException? allowOnline}) async {
    try {
      await widget.speech.toggle(
        id: widget.id,
        text: widget.text,
        languageCode: widget.languageCode ?? '',
        allowOnline: allowOnline,
      );
    } on Object catch (error) {
      _failed(error, allowOnline, (consent) => _toggle(allowOnline: consent));
    }
  }

  Future<void> _speakSlowly({ConsentRequiredException? allowOnline}) async {
    final languageCode = widget.languageCode;
    if (!_enabled || languageCode == null) return;
    try {
      await widget.speech.speak(
        id: widget.id,
        text: widget.text,
        languageCode: languageCode,
        slow: true,
        allowOnline: allowOnline,
      );
    } on Object catch (error) {
      _failed(
        error,
        allowOnline,
        (consent) => _speakSlowly(allowOnline: consent),
      );
    }
  }

  /// Reports [error]; offers to listen through the Mozhi instance it names
  /// (asked once: not after a refusal with consent).
  void _failed(
    Object error,
    ConsentRequiredException? asked,
    Future<void> Function(ConsentRequiredException consent) again,
  ) {
    if (!mounted) return;
    final consent = switch (error) {
      SpeechUnavailableException(:final onlineConsent?) when asked == null =>
        onlineConsent,
      _ => null,
    };
    widget.onError?.call(
      error,
      consent == null ? null : () => unawaited(again(consent)),
    );
  }

  void _listenSlowly() => unawaited(_speakSlowly());

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
    final label = _playing ? l10n.commonStop : l10n.commonListen;
    // The label is the button's semantics label (via the icons); the
    // tooltip adds the long press for sighted users and handles it.
    final button = Tooltip(
      message: enabled ? l10n.translateListenTooltip(label) : label,
      excludeFromSemantics: true,
      triggerMode: TooltipTriggerMode.longPress,
      onTriggered: enabled ? _listenSlowly : null,
      // The long press vibrates only with haptic feedback on.
      enableFeedback: Haptics.enabled(context),
      child: IconButton(
        key: const Key('quick_translate_listen'),
        // An accent toolbar icon, like the compose sheet's.
        color: Theme.of(context).colorScheme.primary,
        isSelected: _playing,
        icon: Icon(Icons.volume_up_outlined, semanticLabel: label),
        selectedIcon: Icon(Icons.stop_circle_outlined, semanticLabel: label),
        onPressed: enabled || _playing ? () => unawaited(_toggle()) : null,
      ),
    );
    if (!enabled) return button;
    return MenuAnchor(
      controller: _menu,
      menuChildren: [
        MenuItemButton(
          key: const Key('quick_translate_listen_slowly_menu_item'),
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
  }
}
