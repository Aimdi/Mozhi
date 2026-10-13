import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/speech/speech_service.dart';

/// Settings switch for [SpeechService.preferDeviceVoice]. Reads the
/// [SpeechService] from context; renders nothing on platforms without a
/// device speech engine.
class PreferDeviceVoiceTile extends StatefulWidget {
  const new({super.key});

  @override
  State<PreferDeviceVoiceTile> createState() => _PreferDeviceVoiceTileState();
}

class _PreferDeviceVoiceTileState extends State<PreferDeviceVoiceTile> {
  late final SpeechService _speech = context.read<SpeechService>();
  late bool _enabled = _speech.preferDeviceVoice;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final enabled = await _speech.loadPreferDeviceVoice();
    if (mounted) setState(() => _enabled = enabled);
  }

  Future<void> _set({required bool enabled}) async {
    setState(() => _enabled = enabled);
    try {
      await _speech.setPreferDeviceVoice(enabled: enabled);
    } on Object {
      // Not persisted, but still applies for this session.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_speech.deviceVoiceSupported) return const SizedBox.shrink();
    final l10n = context.l10n;
    return SwitchListTile(
      secondary: const Icon(Icons.record_voice_over_outlined),
      title: Text(l10n.speechPreferDeviceVoice),
      subtitle: Text(l10n.speechPreferDeviceVoiceDescription),
      value: _enabled,
      onChanged: (enabled) => _set(enabled: enabled),
    );
  }
}
