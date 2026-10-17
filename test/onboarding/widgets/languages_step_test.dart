import 'dart:async';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/offline/cubit/offline_models_cubit.dart';
import 'package:mozhi/offline/data/offline_model_details.dart';
import 'package:mozhi/onboarding/onboarding.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers.dart';

const _french = Language(code: 'fr', name: 'French', nativeName: 'Français');
const _german = Language(code: 'de', name: 'German', nativeName: 'Deutsch');
const _japanese = Language(code: 'ja', name: 'Japanese');

/// An engine that is still loading its languages.
class _SlowDetails implements OfflineModelDetails {
  final gate = Completer<void>();

  @override
  int downloadSize(String code) => 0;

  @override
  Future<OfflineStorage> storage(Iterable<String> codes) async {
    await gate.future;
    return const OfflineStorage();
  }

  @override
  Future<void> download(
    String code, {
    required bool wifiOnly,
    void Function(double fraction)? onProgress,
  }) async {}
}

void main() {
  setUpAll(registerOnboardingFallbacks);

  group('offlineCodeFor', () {
    const languages = [
      OfflineLanguage(code: 'en', name: 'English'),
      OfflineLanguage(code: 'pt', name: 'Portuguese'),
      OfflineLanguage(code: 'zh', name: 'Chinese'),
    ];

    test('maps catalogue languages onto the engine codes', () {
      expect(
        offlineCodeFor(const Language(code: 'en', name: 'English'), languages),
        'en',
      );
      expect(
        offlineCodeFor(
          const Language(code: 'pt-BR', name: 'Portuguese (Brazil)'),
          languages,
        ),
        'pt',
      );
      expect(offlineCodeFor(_german, languages), isNull);
    });

    test('never maps auto, custom or an empty list', () {
      expect(offlineCodeFor(Language.auto, languages), isNull);
      expect(
        offlineCodeFor(
          const Language(code: 'Pirate', name: 'Pirate', isCustom: true),
          languages,
        ),
        isNull,
      );
      expect(offlineCodeFor(_french, const []), isNull);
    });

    test('keeps Traditional Chinese targets off Simplified models', () {
      const traditional = Language(
        code: 'zh-TW',
        name: 'Chinese (Traditional)',
      );
      expect(offlineCodeFor(traditional, languages), 'zh');
      expect(offlineCodeFor(traditional, languages, isTarget: true), isNull);
    });
  });

  group('LanguagesStep', () {
    late FakeOfflineTranslator translator;

    setUp(() => translator = FakeOfflineTranslator());

    Future<(MockOnboardingCubit, OfflineModelsCubit)> pump(
      WidgetTester tester, {
      AppSettings settings = testSettings,
      OfflineModelsCubit? offline,
      Size size = const Size(420, 1600),
    }) async {
      tester.setScreenSize(size);
      final onboarding = createOnboardingCubit();
      final models = offline ?? await createOfflineModels(translator);
      addTearDown(models.close);
      await tester.pumpOnboarding(
        const LanguagesStep(),
        onboarding: onboarding,
        offline: models,
        settings: createSettings(settings),
      );
      await tester.pumpAndSettle();
      return (onboarding, models);
    }

    testWidgets('shows the default languages', (tester) async {
      await pump(tester);
      expect(find.text('Pick your languages'), findsOneWidget);
      expect(find.text('Translate from'), findsOneWidget);
      expect(find.text('Detect language'), findsOneWidget);
      expect(find.text('Translate into'), findsOneWidget);
      expect(find.text('English'), findsWidgets);
    });

    testWidgets('picks a target in the searchable list', (tester) async {
      final (cubit, _) = await pump(tester);
      await tester.tap(find.byKey(const Key('onboarding_target_language')));
      await tester.pumpAndSettle();
      expect(find.byType(OnboardingLanguagePicker), findsOneWidget);
      // The target list has no "Detect language".
      expect(
        find.descendant(
          of: find.byType(OnboardingLanguagePicker),
          matching: find.text('Detect language'),
        ),
        findsNothing,
      );
      await tester.enterText(
        find.byKey(const Key('onboarding_language_search')),
        'deutsch',
      );
      await tester.pumpAndSettle();
      // Marked when the device can translate it offline.
      expect(find.text('Deutsch · Available offline'), findsOneWidget);
      await tester.tap(find.text('German'));
      await tester.pumpAndSettle();
      verify(
        () => cubit.setTargetLanguage(
          any(that: isA<Language>().having((l) => l.code, 'code', 'de')),
        ),
      ).called(1);
    });

    testWidgets('picks detect language as the source', (tester) async {
      final (cubit, _) = await pump(
        tester,
        settings: const AppSettings(instances: testInstances, source: _german),
      );
      await tester.tap(find.byKey(const Key('onboarding_source_language')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(OnboardingLanguagePicker),
          matching: find.text('Detect language'),
        ),
      );
      await tester.pumpAndSettle();
      verify(() => cubit.setSourceLanguage(Language.auto)).called(1);
    });

    testWidgets('dismissing the picker changes nothing', (tester) async {
      final (cubit, _) = await pump(tester);
      await tester.tap(find.byKey(const Key('onboarding_source_language')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('onboarding_language_search')),
        'no such language',
      );
      await tester.pumpAndSettle();
      expect(
        find.text('No language matches “no such language”.'),
        findsOneWidget,
      );
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      verifyNever(() => cubit.setSourceLanguage(any()));
    });

    testWidgets('offers the picked languages for download with sizes', (
      tester,
    ) async {
      await pump(
        tester,
        settings: const AppSettings(
          instances: testInstances,
          source: _german,
          target: _french,
        ),
      );
      expect(find.text('Use them offline'), findsOneWidget);
      final german = find.byKey(const ValueKey('onboarding_offline_de'));
      final french = find.byKey(const ValueKey('onboarding_offline_fr'));
      expect(german, findsOneWidget);
      expect(french, findsOneWidget);
      expect(
        find.descendant(
          of: german,
          matching: find.text('Deutsch · 40.0 MB download'),
        ),
        findsOneWidget,
      );
      expect(find.text('Download over Wi-Fi only'), findsOneWidget);
      expect(
        find.text(
          'On mobile data or a metered network, Mozhi asks before '
          'downloading',
        ),
        findsOneWidget,
      );
    });

    testWidgets('English needs no download', (tester) async {
      await pump(tester);
      final english = find.byKey(const ValueKey('onboarding_offline_en'));
      expect(english, findsOneWidget);
      expect(
        find.descendant(of: english, matching: find.text('No download needed')),
        findsOneWidget,
      );
      // With "Detect language", the source languages come later.
      expect(find.textContaining('With Detect language'), findsOneWidget);
    });

    testWidgets('says which languages need an online service', (tester) async {
      await pump(
        tester,
        settings: const AppSettings(
          instances: testInstances,
          source: _japanese,
          target: _french,
        ),
      );
      expect(
        find.text(
          'Japanese can’t be translated on this device yet, so Mozhi needs '
          'an online service for it.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('onboarding_offline_fr')), findsOne);
    });

    testWidgets('downloads, deletes and remembers Wi-Fi only', (tester) async {
      final (_, models) = await pump(
        tester,
        settings: const AppSettings(instances: testInstances, target: _french),
      );
      final french = find.byKey(const ValueKey('onboarding_offline_fr'));
      await tester.tap(
        find.descendant(of: french, matching: find.text('Download')),
      );
      await tester.pumpAndSettle();
      expect(translator.downloads, [('fr', true)]);
      expect(find.text('French is ready for offline use'), findsOneWidget);

      await tester.tap(find.text('Download over Wi-Fi only'));
      await tester.pumpAndSettle();
      expect(models.state.wifiOnly, isFalse);

      expect(
        find.descendant(
          of: french,
          matching: find.text('Français · 40.0 MB on this device'),
        ),
        findsOneWidget,
      );
      // Deleting asks first.
      await tester.tap(find.byTooltip('Delete French'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(translator.downloaded, contains('fr'));
      await tester.tap(find.byTooltip('Delete French'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(translator.downloaded, isNot(contains('fr')));
    });

    testWidgets('shows the progress of a running download', (tester) async {
      translator.gate = Completer<void>();
      await pump(
        tester,
        settings: const AppSettings(instances: testInstances, target: _french),
      );
      final french = find.byKey(const ValueKey('onboarding_offline_fr'));
      await tester.tap(
        find.descendant(of: french, matching: find.text('Download')),
      );
      await tester.pump();
      expect(
        find.descendant(
          of: french,
          matching: find.text('Français · Downloading… 50%'),
        ),
        findsOneWidget,
      );
      translator.gate!.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('asks before downloading over mobile data', (tester) async {
      translator.failWith = const MeteredConnectionException();
      await pump(
        tester,
        settings: const AppSettings(instances: testInstances, target: _french),
      );
      final french = find.byKey(const ValueKey('onboarding_offline_fr'));
      await tester.tap(
        find.descendant(of: french, matching: find.text('Download')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Download over mobile data?'), findsOneWidget);
      await tester.tap(find.text('Download anyway'));
      await tester.pumpAndSettle();
      expect(translator.downloads, [('fr', true), ('fr', false)]);
      expect(translator.downloaded, contains('fr'));
    });

    testWidgets('cancelling the mobile data prompt keeps waiting for Wi-Fi', (
      tester,
    ) async {
      translator.failWith = const MeteredConnectionException();
      await pump(
        tester,
        settings: const AppSettings(instances: testInstances, target: _french),
      );
      final french = find.byKey(const ValueKey('onboarding_offline_fr'));
      await tester.tap(
        find.descendant(of: french, matching: find.text('Download')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(translator.downloads, [('fr', true)]);
      expect(translator.downloaded, isNot(contains('fr')));
    });

    testWidgets('shows a loading indicator while the engine loads', (
      tester,
    ) async {
      final details = _SlowDetails();
      final models = OfflineModelsCubit(
        translator: translator,
        store: MemoryStore(),
        details: details,
      );
      unawaited(models.load());
      tester.setScreenSize(const Size(420, 1600));
      addTearDown(models.close);
      await tester.pumpOnboarding(
        const LanguagesStep(),
        onboarding: createOnboardingCubit(),
        offline: models,
        settings: createSettings(),
      );
      await tester.pump();
      expect(find.bySemanticsLabel('Checking offline languages…'), findsOne);
      details.gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('Use them offline'), findsOneWidget);
    });

    testWidgets('explains a device without an offline engine', (tester) async {
      translator = FakeOfflineTranslator(isAvailable: false);
      await pump(tester);
      expect(find.textContaining('can’t translate on its own'), findsOne);
      expect(find.text('Use them offline'), findsNothing);
    });
  });

  group('OnboardingOfflineLanguageRow', () {
    const french = OfflineLanguage(
      code: 'fr',
      name: 'French',
      nativeName: 'Français',
    );

    Future<List<String>> pump(
      WidgetTester tester,
      OnboardingOfflineLanguageRow Function(
        VoidCallback download,
        VoidCallback delete,
      )
      build, {
      Size size = const Size(600, 400),
    }) async {
      final calls = <String>[];
      tester.setScreenSize(size);
      await tester.pumpOnboarding(
        build(() => calls.add('download'), () => calls.add('delete')),
      );
      return calls;
    }

    testWidgets('puts the action next to the name on wide rows', (
      tester,
    ) async {
      final calls = await pump(
        tester,
        (download, delete) => OnboardingOfflineLanguageRow(
          language: french,
          downloaded: false,
          downloadSize: 1024 * 1024,
          onDownload: download,
          onDelete: delete,
        ),
      );
      final name = tester.getRect(find.text('French'));
      final button = tester.getRect(find.text('Download'));
      expect(button.left, greaterThan(name.right));
      expect((button.center.dy - name.center.dy).abs(), lessThan(24));
      await tester.tap(find.text('Download'));
      expect(calls, ['download']);
      expect(find.byTooltip('Download French'), findsOneWidget);
    });

    testWidgets('puts the action below the name on narrow rows', (
      tester,
    ) async {
      await pump(
        tester,
        size: const Size(360, 400),
        (download, delete) => OnboardingOfflineLanguageRow(
          language: french,
          downloaded: false,
          onDownload: download,
          onDelete: delete,
        ),
      );
      final name = tester.getRect(find.text('French'));
      final button = tester.getRect(find.text('Download'));
      expect(button.top, greaterThan(name.bottom));
      expect(find.text('Français'), findsOneWidget);
    });

    testWidgets('offers an update for an outdated model', (tester) async {
      final calls = await pump(
        tester,
        (download, delete) => OnboardingOfflineLanguageRow(
          language: french,
          downloaded: true,
          outdated: true,
          downloadSize: 2 * 1024 * 1024,
          onDownload: download,
          onDelete: delete,
        ),
      );
      expect(find.text('Français · Update available · 2.0 MB'), findsOne);
      await tester.tap(find.text('Update'));
      expect(calls, ['download']);
    });

    testWidgets('says downloaded without a known size', (tester) async {
      await pump(
        tester,
        (download, delete) => OnboardingOfflineLanguageRow(
          language: french,
          downloaded: true,
          onDownload: download,
          onDelete: delete,
        ),
      );
      expect(find.text('Français · Downloaded'), findsOneWidget);
      expect(find.byTooltip('Delete French'), findsOneWidget);
    });

    for (final (operation, progress, text) in [
      (OfflineModelOperation.download, null, 'Downloading…'),
      (OfflineModelOperation.update, null, 'Updating…'),
      (OfflineModelOperation.update, 0.25, 'Updating… 25%'),
      (OfflineModelOperation.delete, null, 'Deleting…'),
    ]) {
      testWidgets('shows "$text" while busy', (tester) async {
        await pump(
          tester,
          (download, delete) => OnboardingOfflineLanguageRow(
            language: french,
            downloaded: true,
            pending: operation,
            progress: progress,
            onDownload: download,
            onDelete: delete,
          ),
        );
        expect(find.text('Français · $text'), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(find.byTooltip('Delete French'), findsNothing);
      });
    }
  });
}
