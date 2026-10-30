import 'dart:async';

import 'package:bergamot_translator/bergamot_translator.dart'
    show MeteredConnectionException;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/offline/data/offline_model_details.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

final _offline = TranslationEngine.offline();

/// An on-device engine whose downloads the test controls.
class _Translator implements OfflineTranslator {
  new({Set<String> downloaded = const {}}) : downloaded = {'en', ...downloaded};

  final Set<String> downloaded;

  /// The `wifiOnly` of every download, by language.
  final downloads = <(String, bool)>[];

  /// Thrown by the next downloads, in turn.
  final failures = <Exception>[];

  /// Holds a download until completed.
  Completer<void>? gate;

  @override
  bool get isAvailable => true;

  @override
  Set<String> get supportedLanguages => const {'en', 'fr', 'de'};

  @override
  Future<Set<String>> downloadedLanguages() async => {...downloaded};

  @override
  Future<void> downloadLanguage(String code, {bool wifiOnly = true}) async {
    downloads.add((code, wifiOnly));
    await gate?.future;
    if (failures.isNotEmpty) throw failures.removeAt(0);
    downloaded.add(code);
  }

  @override
  Future<void> deleteLanguage(String code) async => downloaded.remove(code);

  @override
  Future<String> translate(
    String text, {
    required String source,
    required String target,
  }) async => text;

  @override
  Future<String?> identifyLanguage(String text) async => null;

  @override
  Future<void> dispose() async {}
}

const OfflineDownload _french = (code: 'fr', name: 'French', bytes: null);
const OfflineDownload _german = (code: 'de', name: 'German', bytes: null);

void main() {
  setUpAll(registerTranslateFallbacks);

  late _Translator translator;

  setUp(() => translator = _Translator());

  /// The translate screen with the on-device engine ([engine]) and the
  /// action for [downloads].
  Future<TranslateHarness> pump(
    WidgetTester tester, {
    List<OfflineDownload> downloads = const [_french],
    TranslationEngine? engine,
    VoidCallback? onManaged,
  }) async {
    final harness = TranslateHarness(
      state: readyState(engine: engine ?? _offline)
          .copyWith(engines: [deepl, _offline]),
    );
    await harness.pump(
      tester,
      child: OfflineDownloadAction(
        downloads: downloads,
        translator: translator,
        store: MemoryStore(),
        onManaged: onManaged,
      ),
    );
    return harness;
  }

  Future<void> tapDownload(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('translate_offline_download')));
    await tester.pumpAndSettle();
  }

  /// Taps Download where a dialog then shows over the running spinner.
  Future<void> tapDownloadToDialog(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('translate_offline_download')));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('downloads right here, then translates on the device', (
    tester,
  ) async {
    final harness = await pump(tester);
    expect(find.text('Download French'), findsOneWidget);
    expect(find.text('Manage languages'), findsOneWidget);

    translator.gate = Completer<void>();
    await tester.tap(find.byKey(const Key('translate_offline_download')));
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const Key('translate_offline_downloading')),
      findsOneWidget,
    );
    expect(find.text('Downloading French…'), findsOneWidget);
    verifyNever(harness.translate.translate);

    translator.gate!.complete();
    await tester.pumpAndSettle();
    expect(translator.downloads, [('fr', true)]);
    // The on-device engine is selected: the text is translated again.
    verify(harness.translate.translate).called(1);
    verifyNever(() => harness.translate.selectEngine(any()));
  });

  testWidgets('shows the progress the engine reports', (tester) async {
    final harness = TranslateHarness(
      state: readyState(engine: _offline).copyWith(engines: [deepl, _offline]),
    );
    translator.gate = Completer<void>();
    await harness.pump(
      tester,
      child: OfflineDownloadAction(
        downloads: const [_french],
        translator: translator,
        store: MemoryStore(),
        details: _Details(translator),
      ),
    );
    await tester.tap(find.byKey(const Key('translate_offline_download')));
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Downloading French… 40%'), findsOneWidget);
    translator.gate!.complete();
    await tester.pumpAndSettle();
    verify(harness.translate.translate).called(1);
  });

  testWidgets('switches to the on-device engine from another one', (
    tester,
  ) async {
    final harness = await pump(tester, engine: deepl);
    await tapDownload(tester);
    verify(() => harness.translate.selectEngine(_offline)).called(1);
  });

  testWidgets('downloads every missing language in turn', (tester) async {
    translator = _Translator(downloaded: {'de'});
    final harness = await pump(tester, downloads: const [_french, _german]);
    expect(find.text('Download French, German'), findsOneWidget);
    await tapDownload(tester);
    expect(translator.downloads, [('fr', true)]);
    verify(harness.translate.translate).called(1);
  });

  testWidgets('asks before using mobile data', (tester) async {
    translator.failures.add(const MeteredConnectionException());
    final harness = await pump(tester);
    await tapDownloadToDialog(tester);
    expect(find.text('Download over mobile data?'), findsOneWidget);
    verifyNever(harness.translate.translate);
    await tester.tap(find.text('Download anyway'));
    await tester.pumpAndSettle();
    expect(translator.downloads, [('fr', true), ('fr', false)]);
    verify(harness.translate.translate).called(1);
  });

  testWidgets('waits for Wi-Fi when the user says no', (tester) async {
    translator.failures.add(const MeteredConnectionException());
    final harness = await pump(tester);
    await tapDownloadToDialog(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(translator.downloads, [('fr', true)]);
    expect(find.byKey(const Key('translate_offline_download')), findsOne);
    verifyNever(harness.translate.translate);
  });

  testWidgets('says why a download failed and tries again', (tester) async {
    translator.failures.add(const FormatException('disk'));
    final harness = await pump(tester);
    await tapDownload(tester);
    expect(
      find.byKey(const Key('translate_offline_download_error')),
      findsOneWidget,
    );
    verifyNever(harness.translate.translate);

    await tapDownload(tester);
    expect(
      find.byKey(const Key('translate_offline_download_error')),
      findsNothing,
    );
    verify(harness.translate.translate).called(1);
  });

  testWidgets('Manage languages opens the offline languages', (tester) async {
    var managed = 0;
    final harness = await pump(tester, onManaged: () => managed++);
    await tester.tap(find.text('Manage languages'));
    await tester.pumpAndSettle();
    verify(() => harness.router.push<void>(AppRoutes.offline)).called(1);
    expect(managed, 1);
    expect(translator.downloads, isEmpty);
  });

  testWidgets('does nothing without an on-device engine', (tester) async {
    final harness = TranslateHarness();
    await harness.pump(
      tester,
      child: const OfflineDownloadAction(downloads: [_french]),
    );
    await tapDownload(tester);
    verifyNever(harness.translate.translate);
  });

  group('translateOnDevice', () {
    testWidgets('does nothing without an on-device engine listed', (
      tester,
    ) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const SizedBox());
      translateOnDevice(tester.element(find.byType(SizedBox).first));
      verifyNever(harness.translate.translate);
      verifyNever(() => harness.translate.selectEngine(any()));
    });

    testWidgets('does nothing without a translate screen', (tester) async {
      await tester.pumpWidget(const SizedBox());
      translateOnDevice(tester.element(find.byType(SizedBox)));
    });
  });

  group('TranslateErrorView', () {
    const missing = OfflineModelMissingException(['fr']);

    Future<TranslateHarness> pumpError(
      WidgetTester tester, {
      required bool ownError,
    }) async {
      final harness = TranslateHarness(
        state: readyState(engine: _offline).copyWith(
          engines: [deepl, _offline],
          status: TranslateStatus.failure,
          error: () => ownError ? missing : null,
        ),
      );
      await harness.pump(
        tester,
        offline: translator,
        child: TranslateErrorView(
          error: ownError
              ? harness.translate.state.error
              : const OfflineModelMissingException(['fr']),
          onRetry: () {},
        ),
      );
      return harness;
    }

    testWidgets('downloads missing models of the translation right there', (
      tester,
    ) async {
      final harness = await pumpError(tester, ownError: true);
      expect(find.byKey(const Key('translate_error_download')), findsOne);
      expect(find.byKey(const Key('translate_error_fix')), findsNothing);
      await tapDownload(tester);
      expect(translator.downloads, [('fr', true)]);
      verify(harness.translate.translate).called(1);
    });

    testWidgets('elsewhere it opens the offline languages', (tester) async {
      await pumpError(tester, ownError: false);
      expect(find.byKey(const Key('translate_error_download')), findsNothing);
      expect(find.byKey(const Key('translate_error_fix')), findsOneWidget);
    });
  });
}

/// Sizes and progress for [_Translator] (40 % reported at once).
class _Details implements OfflineModelDetails {
  new(this.translator);

  final _Translator translator;

  @override
  int downloadSize(String code) => code == 'en' ? 0 : 1000;

  @override
  Future<OfflineStorage> storage(Iterable<String> codes) async =>
      const OfflineStorage();

  @override
  Future<void> download(
    String code, {
    required bool wifiOnly,
    void Function(double fraction)? onProgress,
  }) async {
    onProgress?.call(0.4);
    await translator.downloadLanguage(code, wifiOnly: wifiOnly);
  }
}
