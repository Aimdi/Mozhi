import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  const german = Language(code: 'de', name: 'German');
  const french = Language(code: 'fr', name: 'French');

  group(ConversationPreferences, () {
    test('round-trips through JSON', () {
      const preferences = ConversationPreferences(
        languageA: german,
        languageB: french,
        detectSpeaker: false,
        turnPause: Duration(milliseconds: 1500),
      );
      expect(
        ConversationPreferences.fromJson(preferences.toJson()),
        preferences,
      );
    });

    test('falls back to the defaults for missing or invalid values', () {
      expect(
        ConversationPreferences.fromJson(const {
          'languageA': {'code': 'auto', 'name': 'Detect language'},
          'languageB': 'nonsense',
          'detectSpeaker': 'yes',
          'turnPauseMs': -4,
        }),
        const ConversationPreferences(),
      );
    });

    test('is kept in the app settings', () {
      const settings = AppSettings(
        conversation: ConversationPreferences(languageA: german),
      );
      final restored = AppSettings.fromJson(settings.toJson());
      expect(restored.conversation.languageA, german);
      expect(
        settings.copyWith(conversation: const ConversationPreferences()),
        const AppSettings(),
      );
      expect(
        AppSettings.fromJson(const {}).conversation,
        const ConversationPreferences(),
      );
    });
  });

  test('SettingsCubit.setConversationPreferences keeps them', () async {
    final cubit = SettingsCubit();
    addTearDown(cubit.close);
    const preferences = ConversationPreferences(detectSpeaker: false);
    final states = <AppSettings>[];
    final sub = cubit.stream.listen(states.add);
    addTearDown(sub.cancel);

    cubit
      ..setConversationPreferences(preferences)
      ..setConversationPreferences(preferences);
    await pumpEventQueue();

    expect(cubit.state.conversation, preferences);
    expect(states, hasLength(1));
  });
}
