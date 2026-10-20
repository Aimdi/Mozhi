import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';
import 'package:mozhi/settings/view/widgets/voice_input_settings_section.dart';
import 'package:translation_repository/translation_repository.dart'
    show PrivacyMode;

/// The "Voice input" settings on a page of their own
/// (`VoiceInputButton.settingsLocation`), opened from voice input errors to
/// download the offline speech model. The same [VoiceInputSettingsSection]
/// as on the settings page; reads the app-wide [SettingsCubit].
class VoiceInputSettingsPage extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final privacyMode = context.select<SettingsCubit, PrivacyMode>(
      (cubit) => cubit.state.privacyMode,
    );
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.voiceSettingsTitle)),
      body: LayoutBuilder(
        builder: (context, constraints) => ListView(
          padding: centeredPadding(constraints.maxWidth),
          children: [VoiceInputSettingsSection(privacyMode: privacyMode)],
        ),
      ),
    );
  }
}
