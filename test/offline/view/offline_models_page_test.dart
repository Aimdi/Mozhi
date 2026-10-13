import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/offline/offline.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../helpers/helpers.dart';
import '../helpers.dart';

void main() {
  late MockOfflineTranslator translator;
  late MemoryStore store;

  setUp(() {
    translator = stubOfflineTranslator();
    store = MemoryStore();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpApp(OfflineModelsPage(translator: translator, store: store));
    await tester.pumpAndSettle();
  }

  Finder section(String title) => find.ancestor(
    of: find.text(title),
    matching: find.byType(Column),
  ).first;

  group('OfflineModelsPage', () {
    testWidgets('shows a spinner while loading', (tester) async {
      final completer = Completer<Set<String>>();
      when(translator.downloadedLanguages).thenAnswer((_) => completer.future);
      await tester.pumpApp(
        OfflineModelsPage(translator: translator, store: store),
      );
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      completer.complete({'en'});
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('lists downloaded and available languages', (tester) async {
      await pumpPage(tester);
      expect(find.text('Offline languages'), findsOneWidget);
      expect(find.text('2 languages downloaded'), findsOneWidget);
      expect(find.text('Downloaded'), findsNWidgets(3)); // header + 2 badges
      expect(find.text('Available to download'), findsOneWidget);
      expect(find.text('Offline translation is available on Android and iOS'),
          findsNothing);

      final downloaded = section('Downloaded').evaluate().first;
      expect(
        find.descendant(
          of: find.byWidget(downloaded.widget),
          matching: find.byType(OfflineLanguageTile),
        ),
        findsNWidgets(2),
      );
      // Sorted by name; unknown codes fall back to the code.
      final names = tester
          .widgetList<OfflineLanguageTile>(find.byType(OfflineLanguageTile))
          .map((tile) => tile.language.name)
          .toList();
      expect(names, ['English', 'German', 'French', 'Japanese', 'xx']);
    });

    testWidgets('shows a banner and disables actions when unavailable', (
      tester,
    ) async {
      translator = stubOfflineTranslator(available: false);
      await pumpPage(tester);
      expect(
        find.text('Offline translation is available on Android and iOS'),
        findsOneWidget,
      );
      expect(find.text('No languages downloaded'), findsOneWidget);
      await tester.tap(find.byTooltip('Download French'));
      final toggle = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
      expect(toggle.onChanged, isNull);
      verifyNever(
        () => translator.downloadLanguage(
          any(),
          wifiOnly: any(named: 'wifiOnly'),
        ),
      );
    });

    testWidgets('shows a retry button when loading fails', (tester) async {
      when(translator.downloadedLanguages).thenThrow(StateError('plugin'));
      await pumpPage(tester);
      expect(
        find.text('Couldn’t check which languages are downloaded'),
        findsOneWidget,
      );
      when(translator.downloadedLanguages).thenAnswer((_) async => {'en'});
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('1 language downloaded'), findsOneWidget);
    });

    testWidgets('downloads a language with progress and a snackbar', (
      tester,
    ) async {
      final completer = Completer<void>();
      when(
        () => translator.downloadLanguage(
          any(),
          wifiOnly: any(named: 'wifiOnly'),
        ),
      ).thenAnswer((_) => completer.future);
      await pumpPage(tester);

      await tester.tap(find.byTooltip('Download French'));
      await tester.pump();
      expect(find.text('Downloading when on Wi-Fi…'), findsOneWidget);
      verify(() => translator.downloadLanguage('fr', wifiOnly: true)).called(1);

      completer.complete();
      await tester.pumpAndSettle();
      expect(find.text('French is ready for offline use'), findsOneWidget);
      expect(find.text('3 languages downloaded'), findsOneWidget);
      expect(find.byTooltip('Delete French'), findsOneWidget);
    });

    testWidgets('reports a failed download', (tester) async {
      when(
        () => translator.downloadLanguage(
          any(),
          wifiOnly: any(named: 'wifiOnly'),
        ),
      ).thenThrow(Exception('network'));
      await pumpPage(tester);
      await tester.tap(find.byTooltip('Download Japanese'));
      await tester.pumpAndSettle();
      expect(find.text('Couldn’t download Japanese'), findsOneWidget);
      expect(find.byTooltip('Download Japanese'), findsOneWidget);
    });

    testWidgets('deletes a language after confirmation', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.byTooltip('Delete German'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      verifyNever(() => translator.deleteLanguage(any()));

      await tester.tap(find.byTooltip('Delete German'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();
      verify(() => translator.deleteLanguage('de')).called(1);
      expect(find.text('German deleted'), findsOneWidget);
      expect(find.text('1 language downloaded'), findsOneWidget);
    });

    testWidgets('reports a failed deletion', (tester) async {
      when(() => translator.deleteLanguage(any())).thenThrow(Exception('busy'));
      await pumpPage(tester);
      await tester.tap(find.byTooltip('Delete English'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Couldn’t delete English'), findsOneWidget);
    });

    testWidgets('persists the Wi-Fi only switch', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.text('Download over Wi-Fi only'));
      await tester.pumpAndSettle();
      expect(store.values[OfflineModelsCubit.wifiOnlyKey], 'false');

      await tester.tap(find.byTooltip('Download French'));
      await tester.pumpAndSettle();
      verify(() => translator.downloadLanguage('fr', wifiOnly: false)).called(1);
    });

    testWidgets('searches languages', (tester) async {
      await pumpPage(tester);
      await tester.enterText(find.byType(TextField), 'fren');
      await tester.pumpAndSettle();
      expect(find.byType(OfflineLanguageTile), findsOneWidget);
      expect(find.text('French'), findsOneWidget);
      expect(find.text('Downloaded'), findsNothing);

      await tester.enterText(find.byType(TextField), 'klingon');
      await tester.pumpAndSettle();
      expect(find.text('No languages match “klingon”'), findsOneWidget);

      await tester.tap(find.byTooltip('Clear'));
      await tester.pumpAndSettle();
      expect(find.byType(OfflineLanguageTile), findsNWidgets(5));
      expect(find.byTooltip('Clear'), findsNothing);
    });

    testWidgets('uses the provided translator and store', (tester) async {
      store.values[OfflineModelsCubit.wifiOnlyKey] = 'false';
      await tester.pumpApp(
        MultiRepositoryProvider(
          providers: [
            RepositoryProvider<OfflineTranslator>.value(value: translator),
            RepositoryProvider<KeyValueStore>.value(value: store),
          ],
          child: const OfflineModelsPage(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('2 languages downloaded'), findsOneWidget);
      final toggle = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
      expect(toggle.value, isFalse);
    });

    testWidgets(
      'falls back to ML Kit and the preferences',
      (tester) async {
        await tester.pumpApp(const OfflineModelsPage());
        await tester.pumpAndSettle();
        expect(
          find.text('Offline translation is available on Android and iOS'),
          findsOneWidget,
        );
        expect(find.byType(OfflineLanguageTile), findsWidgets);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.linux),
    );
  });
}
