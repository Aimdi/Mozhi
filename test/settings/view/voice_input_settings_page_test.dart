import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/voice_input_settings_page.dart';
import 'package:mozhi/settings/view/widgets/voice_input_settings_section.dart';
import 'package:mozhi/voice/voice.dart';
import 'package:translation_repository/translation_repository.dart'
    show PrivacyMode;

import '../../helpers/helpers.dart';
import '../../voice/helpers/fake_speech_recognizer.dart';
import 'helpers.dart';

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  late SpeechInputService speech;

  setUp(() {
    speech = SpeechInputService(
      store: MemoryStore(),
      adapter: FakeSpeechRecognizer(),
      platformSupported: true,
      onDeviceSupported: true,
    );
  });

  tearDown(() => speech.dispose());

  Future<void> pumpPage(WidgetTester tester, AppSettings settings) =>
      tester.pumpApp(
        MultiRepositoryProvider(
          providers: [RepositoryProvider.value(value: speech)],
          child: BlocProvider<SettingsCubit>.value(
            value: createSettingsCubit(settings),
            child: const VoiceInputSettingsPage(),
          ),
        ),
      );

  group(VoiceInputSettingsPage, () {
    testWidgets('shows the voice input settings', (tester) async {
      await pumpPage(tester, const AppSettings());
      await tester.pump();

      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text(l10n.voiceSettingsTitle),
        ),
        findsOneWidget,
      );
      expect(find.byType(VoiceInputSettingsSection), findsOneWidget);
      expect(find.byType(PreferOnDeviceSpeechTile), findsOneWidget);
      expect(find.byKey(const Key('voice_offline_only_note')), findsNothing);
    });

    testWidgets('follows the privacy mode', (tester) async {
      await pumpPage(
        tester,
        const AppSettings(privacyMode: PrivacyMode.offlineOnly),
      );
      await tester.pump();

      expect(find.byKey(const Key('voice_offline_only_note')), findsOneWidget);
      expect(find.byType(PreferOnDeviceSpeechTile), findsNothing);
    });
  });
}
