import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/widgets/widgets.dart';

import '../helpers/fake_offline.dart';
import '../helpers/helpers.dart';

void main() {
  setUpAll(registerTranslateFallbacks);

  final l10n = lookupAppLocalizations(const Locale('en'));

  group('offlineLanguageKey', () {
    test('compares primary subtags of normalised codes', () {
      expect(offlineLanguageKey('zh-CN'), offlineLanguageKey('zh'));
      expect(offlineLanguageKey('nb'), offlineLanguageKey('no'));
      expect(offlineLanguageKey('pt-BR'), 'pt');
      expect(offlineLanguageKey('DE'), 'de');
    });
  });

  group('offlineReadyLanguages', () {
    test('lists the downloaded languages with English', () async {
      expect(
        await offlineReadyLanguages(
          FakeOfflineTranslator(downloaded: {'de', 'zh'}),
        ),
        {'en', 'de', 'zh'},
      );
    });

    test('is empty with English only, unavailable or failing', () async {
      expect(await offlineReadyLanguages(FakeOfflineTranslator()), isEmpty);
      expect(
        await offlineReadyLanguages(
          FakeOfflineTranslator(isAvailable: false, downloaded: {'de'}),
        ),
        isEmpty,
      );
      expect(
        await offlineReadyLanguages(
          FakeOfflineTranslator(downloaded: {'de'}, fails: true),
        ),
        isEmpty,
      );
    });
  });

  group('offlineDownloadsFor', () {
    test('lists the missing languages of the pair but English', () {
      final downloads = offlineDownloadsFor(
        FakeOfflineTranslator(),
        source: 'de',
        target: 'fr',
        ready: const {},
      );
      expect(downloads, [
        (code: 'de', name: 'German', bytes: null),
        (code: 'fr', name: 'French', bytes: null),
      ]);
      expect(
        offlineDownloadsFor(
          FakeOfflineTranslator(),
          source: 'en',
          target: 'fr-FR',
          ready: const {'en', 'fr'},
        ),
        isEmpty,
      );
    });

    test('only needs the target while detecting', () {
      expect(
        offlineDownloadsFor(
          FakeOfflineTranslator(),
          source: 'auto',
          target: 'ja',
          ready: const {},
        ),
        [(code: 'ja', name: 'Japanese', bytes: null)],
      );
      expect(
        offlineDownloadsFor(
          FakeOfflineTranslator(),
          source: null,
          target: 'en',
          ready: const {},
        ),
        isEmpty,
      );
    });

    test('is null for pairs the device cannot translate', () {
      expect(
        offlineDownloadsFor(
          FakeOfflineTranslator(),
          source: 'en',
          target: 'ko',
          ready: const {},
        ),
        isNull,
      );
      expect(
        offlineDownloadsFor(
          FakeOfflineTranslator(isAvailable: false),
          source: 'en',
          target: 'de',
          ready: const {},
        ),
        isNull,
      );
      expect(
        offlineDownloadsFor(
          FakeOfflineTranslator(),
          source: 'de',
          target: 'auto',
          ready: const {},
        ),
        isNull,
      );
    });

    test('knows Bergamot download sizes', () {
      final downloads = offlineDownloadsFor(
        fakeBergamot(),
        source: 'de',
        target: 'en',
        ready: const {},
      );
      expect(downloads, [
        (code: 'de', name: 'German', bytes: 24 * 1024 * 1024),
      ]);
    });
  });

  group('offlineDownloadLabel', () {
    test('names the languages and their total size', () {
      expect(
        offlineDownloadLabel(l10n, [
          (code: 'de', name: 'German', bytes: 24 * 1024 * 1024),
        ]),
        'Download German (24.0 MB)',
      );
      expect(
        offlineDownloadLabel(l10n, [
          (code: 'de', name: 'German', bytes: 20 * 1024 * 1024),
          (code: 'fr', name: 'French', bytes: 10 * 1024 * 1024),
        ]),
        'Download German, French (30.0 MB)',
      );
    });

    test('leaves out an unknown size', () {
      expect(
        offlineDownloadLabel(l10n, [
          (code: 'de', name: 'German', bytes: 24),
          (code: 'fr', name: 'French', bytes: null),
        ]),
        'Download German, French',
      );
    });
  });

  group('DelayedReveal', () {
    testWidgets('shows its child after the delay only', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const DelayedReveal(child: Text('x')));
      expect(find.text('x'), findsNothing);
      await tester.pump(loadingRevealDelay);
      expect(find.text('x'), findsOneWidget);
    });

    testWidgets('a zero delay shows it at once', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(
        tester,
        child: const DelayedReveal(delay: Duration.zero, child: Text('x')),
      );
      expect(find.text('x'), findsOneWidget);
    });
  });
}
