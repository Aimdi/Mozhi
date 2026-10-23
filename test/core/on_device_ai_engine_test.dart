import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/on_device_ai_engine.dart';
import 'package:mozhi/core/widgets/consent_prompt.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:translation_repository/translation_repository.dart';

const _hyMt = 'ai:device-hy-mt2-1.8b-q4';

void main() {
  group('isOnDeviceAiEngineId', () {
    test('matches the ids of on-device models', () {
      expect(isOnDeviceAiEngineId(_hyMt), isTrue);
      expect(isOnDeviceAiEngineId('ai:device-'), isFalse);
      expect(isOnDeviceAiEngineId('ai:claude'), isFalse);
      expect(isOnDeviceAiEngineId('offline:mlkit'), isFalse);
      expect(isOnDeviceAiEngineId(null), isFalse);
    });
  });

  group('isOnDeviceAiEngine', () {
    test('needs an AI engine the repository marked on device', () {
      expect(
        isOnDeviceAiEngine(
          const TranslationEngine(
            id: 'ai:device-gemma-4-e2b-q4',
            kind: EngineKind.ai,
            name: 'Gemma 4 E2B (on this device)',
            onDevice: true,
          ),
        ),
        isTrue,
      );
      // The id alone proves nothing (a stored provider could take it).
      expect(
        isOnDeviceAiEngine(
          const TranslationEngine(
            id: 'ai:device-gemma-4-e2b-q4',
            kind: EngineKind.ai,
            name: 'Odd',
          ),
        ),
        isFalse,
      );
      expect(isOnDeviceAiEngine(TranslationEngine.offline()), isFalse);
    });
  });

  group('on-device AI destinations', () {
    final l10n = lookupAppLocalizations(const Locale('en'));
    const device = OnDeviceDestination();

    test('read "On this device" with a memory chip', () {
      expect(destinationLabel(l10n, device, engineId: _hyMt), 'On this device');
      expect(
        destinationDescription(l10n, device, engineId: _hyMt),
        l10n.commonDestinationOnDeviceAiBody,
      );
      expect(destinationIcon(device, engineId: _hyMt), Icons.memory);
    });

    test('leave the offline engine as it was', () {
      const offline = TranslationEngine.offlineId;
      expect(destinationLabel(l10n, device, engineId: offline), 'On device');
      expect(
        destinationDescription(l10n, device, engineId: offline),
        l10n.commonDestinationOnDeviceBody,
      );
      expect(destinationIcon(device, engineId: offline), Icons.phone_android);
    });

    testWidgets('the chip and its sheet say so', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Center(
              child: DestinationChip(destination: device, engineId: _hyMt),
            ),
          ),
        ),
      );
      expect(find.text('On this device'), findsOneWidget);
      expect(find.byIcon(Icons.memory), findsOneWidget);

      await tester.tap(find.byType(DestinationChip));
      await tester.pumpAndSettle();
      expect(find.text(l10n.commonDestinationOnDeviceAiBody), findsOneWidget);
      expect(find.byIcon(Icons.memory), findsNWidgets(2));
    });
  });
}
