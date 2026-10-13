import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/voice/voice.dart';

import '../../helpers/helpers.dart';
import '../helpers/fake_speech_recognizer.dart';

class _FailingWriteStore extends MemoryStore {
  @override
  Future<void> write(String key, String value) async =>
      throw Exception('write');
}

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  late MemoryStore store;

  SpeechInputService service({
    bool onDeviceSupported = true,
    KeyValueStore? keyValueStore,
  }) => SpeechInputService(
    store: keyValueStore ?? store,
    adapter: FakeSpeechRecognizer(),
    platformSupported: true,
    onDeviceSupported: onDeviceSupported,
  );

  setUp(() => store = MemoryStore());

  group(PreferOnDeviceSpeechTile, () {
    testWidgets('shows the stored value and persists changes', (tester) async {
      store.values[SpeechInputService.preferOnDeviceKey] = 'true';
      final speech = service();
      await tester.pumpApp(
        Scaffold(body: PreferOnDeviceSpeechTile.standalone(service: speech)),
      );
      await tester.pump();

      expect(find.text(l10n.voicePreferOnDeviceTitle), findsOneWidget);
      expect(find.text(l10n.voicePreferOnDeviceSubtitle), findsOneWidget);
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isTrue,
      );

      await tester.tap(find.byType(SwitchListTile));
      await tester.pump();
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse,
      );
      expect(store.values[SpeechInputService.preferOnDeviceKey], 'false');
      expect(speech.preferOnDevice.value, isFalse);
    });

    testWidgets('reads the service from the context', (tester) async {
      final speech = service();
      await tester.pumpApp(
        RepositoryProvider.value(
          value: speech,
          // Not const, so the constructor counts as covered.
          // ignore: prefer_const_constructors
          child: Scaffold(body: PreferOnDeviceSpeechTile()),
        ),
      );
      await tester.tap(find.byType(SwitchListTile));
      await tester.pump();
      expect(store.values[SpeechInputService.preferOnDeviceKey], 'true');
    });

    testWidgets('keeps the new value when saving fails', (tester) async {
      final speech = service(keyValueStore: _FailingWriteStore());
      await tester.pumpApp(
        Scaffold(body: PreferOnDeviceSpeechTile.standalone(service: speech)),
      );
      await tester.tap(find.byType(SwitchListTile));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(speech.preferOnDevice.value, isTrue);
    });

    testWidgets('is hidden where on-device recognition is unsupported', (
      tester,
    ) async {
      await tester.pumpApp(
        Scaffold(
          body: PreferOnDeviceSpeechTile.standalone(
            service: service(onDeviceSupported: false),
          ),
        ),
      );
      expect(find.byType(SwitchListTile), findsNothing);
    });
  });
}
