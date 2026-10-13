import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:mozhi/speech/widgets/prefer_device_voice_tile.dart';

import '../../helpers/helpers.dart';

class _MockSpeechService extends Mock implements SpeechService;

void main() {
  group(PreferDeviceVoiceTile, () {
    late SpeechService speech;

    setUp(() {
      speech = _MockSpeechService();
      when(() => speech.deviceVoiceSupported).thenReturn(true);
      when(() => speech.preferDeviceVoice).thenReturn(false);
      when(speech.loadPreferDeviceVoice).thenAnswer((_) async => true);
      when(() => speech.setPreferDeviceVoice(enabled: any(named: 'enabled')))
          .thenAnswer((_) async {});
    });

    Future<void> pump(WidgetTester tester) => tester.pumpApp(
      RepositoryProvider<SpeechService>.value(
        value: speech,
        child: const Scaffold(body: PreferDeviceVoiceTile()),
      ),
    );

    bool switchValue(WidgetTester tester) =>
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value;

    testWidgets('shows the stored preference', (tester) async {
      await pump(tester);
      expect(find.text('Use device voice'), findsOneWidget);

      await tester.pump();

      expect(switchValue(tester), isTrue);
    });

    testWidgets('persists changes', (tester) async {
      await pump(tester);
      await tester.pump();

      await tester.tap(find.byType(SwitchListTile));
      await tester.pump();

      expect(switchValue(tester), isFalse);
      verify(() => speech.setPreferDeviceVoice(enabled: false)).called(1);
    });

    testWidgets('keeps the change when saving fails', (tester) async {
      when(() => speech.setPreferDeviceVoice(enabled: any(named: 'enabled')))
          .thenThrow(Exception('disk full'));
      await pump(tester);
      await tester.pump();

      await tester.tap(find.byType(SwitchListTile));
      await tester.pump();

      expect(switchValue(tester), isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('ignores a load that finishes after removal', (tester) async {
      final load = Completer<bool>();
      when(speech.loadPreferDeviceVoice).thenAnswer((_) => load.future);
      await pump(tester);

      await tester.pumpWidget(const SizedBox());
      load.complete(true);
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets('is hidden without a device speech engine', (tester) async {
      when(() => speech.deviceVoiceSupported).thenReturn(false);

      await pump(tester);

      expect(find.byType(SwitchListTile), findsNothing);
    });
  });
}
