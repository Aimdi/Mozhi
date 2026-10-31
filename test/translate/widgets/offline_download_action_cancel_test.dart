import 'dart:async';

import 'package:bergamot_translator/bergamot_translator.dart'
    show ModelDownloadException;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

final _offline = TranslationEngine.offline();

/// An on-device engine whose downloads wait until [cancelDownload] (or
/// [finish]).
class _Cancellable implements CancellableDownloads {
  final downloaded = {'en'};

  /// Every download and cancel, in order.
  final calls = <String>[];

  final _running = <String, Completer<void>>{};

  /// Ends the running download of [code], with [error] when given.
  void finish(String code, {Object? error}) {
    final running = _running.remove(code)!;
    if (error == null) {
      downloaded.add(code);
      running.complete();
    } else {
      running.completeError(error);
    }
  }

  @override
  bool get isAvailable => true;

  @override
  Set<String> get supportedLanguages => const {'en', 'fr', 'de'};

  @override
  Future<Set<String>> downloadedLanguages() async => {...downloaded};

  @override
  Future<void> downloadLanguage(String code, {bool wifiOnly = true}) {
    calls.add('download $code');
    return (_running[code] = Completer<void>()).future;
  }

  @override
  Future<void> cancelDownload(String code) async {
    calls.add('cancel $code');
    _running
        .remove(code)
        ?.completeError(OfflineDownloadCancelledException(code));
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

  late _Cancellable translator;

  setUp(() => translator = _Cancellable());

  Future<TranslateHarness> pump(
    WidgetTester tester, {
    OfflineTranslator? engine,
  }) async {
    final harness = TranslateHarness(
      state: readyState(engine: _offline).copyWith(engines: [deepl, _offline]),
    );
    await harness.pump(
      tester,
      child: OfflineDownloadAction(
        downloads: const [_french, _german],
        translator: engine ?? translator,
        store: MemoryStore(),
      ),
    );
    return harness;
  }

  final cancel = find.byKey(const Key('translate_offline_cancel'));
  final download = find.byKey(const Key('translate_offline_download'));

  Future<void> startDownload(WidgetTester tester) async {
    await tester.tap(download);
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }
  }

  testWidgets('Cancel stops the downloads quietly', (tester) async {
    final handle = tester.ensureSemantics();
    final harness = await pump(tester);
    await startDownload(tester);
    expect(find.text('Downloading French…'), findsOneWidget);
    expect(cancel, findsOneWidget);
    expect(find.bySemanticsLabel('Cancel downloading French'), findsOneWidget);
    final size = tester.getSize(
      find.byKey(const Key('offline_cancel_download')),
    );
    expect(size.height, greaterThanOrEqualTo(48));
    expect(size.width, greaterThanOrEqualTo(48));

    await tester.tap(find.byKey(const Key('offline_cancel_download')));
    await tester.pumpAndSettle();
    expect(translator.calls, ['download fr', 'cancel fr']);
    // Back to the button, without an error and without German.
    expect(download, findsOneWidget);
    expect(cancel, findsNothing);
    expect(
      find.byKey(const Key('translate_offline_download_error')),
      findsNothing,
    );
    expect(find.byType(SnackBar), findsNothing);
    verifyNever(harness.translate.translate);

    // Downloading again starts over with French.
    await startDownload(tester);
    expect(translator.calls.last, 'download fr');
    translator.finish('fr');
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }
    expect(translator.calls.last, 'download de');
    translator.finish('de');
    await tester.pumpAndSettle();
    verify(harness.translate.translate).called(1);
    handle.dispose();
  });

  testWidgets('says Stopping… until the download has stopped', (tester) async {
    final slow = _SlowCancel();
    await pump(tester, engine: slow);
    await startDownload(tester);
    await tester.tap(find.byKey(const Key('offline_cancel_download')));
    await tester.pump();
    expect(find.text('Stopping…'), findsOneWidget);
    final button = tester.widget<TextButton>(
      find.byKey(const Key('offline_cancel_download')),
    );
    expect(button.onPressed, isNull);
    slow.release.complete();
    await tester.pumpAndSettle();
    expect(download, findsOneWidget);
  });

  testWidgets('a failure still says why', (tester) async {
    await pump(tester);
    await startDownload(tester);
    translator.finish(
      'fr',
      error: const ModelDownloadException('en-fr', 'connection reset'),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('translate_offline_download_error')),
      findsOneWidget,
    );
  });
}

/// A [_Cancellable] whose cancel takes until [release] completes.
class _SlowCancel extends _Cancellable {
  final release = Completer<void>();

  @override
  Future<void> cancelDownload(String code) async {
    await release.future;
    await super.cancelDownload(code);
  }
}
