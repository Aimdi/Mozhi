import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/offline/offline.dart';

import '../../helpers/helpers.dart';

void main() {
  const messages = {
    BergamotWebRequirement.engineFiles:
        'This copy of the web app was built without the on-device engine, '
        'so it translates online only.',
    BergamotWebRequirement.secureContext:
        'On-device translation needs a secure connection. Open the web app '
        'over HTTPS.',
    BergamotWebRequirement.storage:
        'This browser doesn’t let the web app store language packs (private '
        'windows often don’t). Open it in a normal window or another '
        'browser.',
    BergamotWebRequirement.wasmSimd:
        'This browser is too old for on-device translation. Update it, or '
        'use a current Chrome, Edge, Firefox or Safari.',
    BergamotWebRequirement.decompression:
        'This browser is too old for on-device translation. Update it, or '
        'use a current Chrome, Edge, Firefox or Safari.',
    BergamotWebRequirement.segmenter:
        'This browser is too old for on-device translation. Update it, or '
        'use a current Chrome, Edge, Firefox or Safari.',
  };

  for (final MapEntry(key: requirement, value: message) in messages.entries) {
    testWidgets('a browser without ${requirement.name} says why', (
      tester,
    ) async {
      await tester.pumpApp(
        OfflineModelsPage(
          translator: UnavailableOfflineTranslator(webRequirement: requirement),
          store: MemoryStore(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(message), findsOneWidget);
      expect(
        find.text('Offline translation is available in the Android app'),
        findsNothing,
      );
    });
  }

  testWidgets('without a reason the device is blamed (Android)', (
    tester,
  ) async {
    await tester.pumpApp(
      OfflineModelsPage(
        translator: const UnavailableOfflineTranslator(),
        store: MemoryStore(),
      ),
    );
    await tester.pumpAndSettle();
    // Tests run as Android, where only the processor can be the reason.
    expect(
      find.text(
        'This device’s processor can’t run the offline translation engine',
      ),
      findsOneWidget,
    );
  });

  test('UnavailableOfflineTranslator has no reason by default', () {
    expect(const UnavailableOfflineTranslator().webRequirement, isNull);
  });
}
