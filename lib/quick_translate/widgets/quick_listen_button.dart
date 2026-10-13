import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/speech/speech_service.dart';

/// Reads the translation aloud through [SpeechService.toggle]; shows a stop
/// icon while the clip with [id] plays. Playback stops when the button is
/// removed (e.g. the quick translate sheet closes).
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
  final VoidCallback? onError;

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

  Future<void> _toggle() async {
    try {
      await widget.speech.toggle(
        id: widget.id,
        text: widget.text,
        languageCode: widget.languageCode ?? '',
      );
    } on Object {
      widget.onError?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final enabled =
        widget.text.trim().isNotEmpty && widget.languageCode != null;
    return IconButton(
      key: const Key('quick_translate_listen'),
      tooltip: _playing ? l10n.commonStop : l10n.commonListen,
      isSelected: _playing,
      icon: const Icon(Icons.volume_up_outlined),
      selectedIcon: const Icon(Icons.stop_circle_outlined),
      onPressed: enabled || _playing ? () => unawaited(_toggle()) : null,
    );
  }
}
