import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/fake_offline.dart';
import '../helpers/helpers.dart';

const _first = MozhiInstance(url: 'https://user:secret@mozhi.one.example');
const _second = MozhiInstance(url: 'https://mozhi.two.example');

final _offline = TranslationEngine.offline();

const _allFailed = AllInstancesFailedException(
  'Post "https://translate.google.com": Forbidden',
  engine: google,
  instances: [_first, _second],
  statusCode: 500,
);

/// A failed English -> French translation with Google with [error].
TranslateState _failed(
  Object error, {
  List<TranslationEngine> engines = const [google, deepl],
}) => readyState(
  engine: google,
  source: english,
  input: 'Hello world',
  status: TranslateStatus.failure,
).copyWith(engines: [...engines, _offline], error: () => error);

void main() {
  setUpAll(registerTranslateFallbacks);

  setUp(() => deviceOfflineCheck = () async => false);

  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  group('describeTranslateError for every server failing', () {
    test('says the volunteer servers failed, in plain words', () {
      final info = describeTranslateError(l10n, _allFailed);
      expect(info.message, l10n.translateErrorAllServersFailed(2, 'Google'));
      expect(info.message, isNot(contains('500')));
      expect(info.title, l10n.translateErrorTitleAllServers);
      expect(info.fix, TranslateErrorFix.instances);
      expect(info.anotherInstanceMayHelp, isFalse);
      expect(
        info.details,
        '${l10n.translateErrorServersTried('mozhi.one.example, '
        'mozhi.two.example')} HTTP 500: Post "https://translate.google.com": '
        'Forbidden',
      );
      expect(info.details, isNot(contains('secret')));
    });

    test('names one server in the singular', () {
      const one = AllInstancesFailedException(
        'refused',
        engine: google,
        instances: [_second],
      );
      final info = describeTranslateError(l10n, one);
      expect(info.message, l10n.translateErrorAllServersFailed(1, 'Google'));
      expect(info.message, startsWith('The volunteer server couldn'));
    });

    test('details without servers to name are the error alone', () {
      const none = AllInstancesFailedException(
        'refused',
        engine: google,
        instances: [MozhiInstance(url: 'not a url')],
      );
      expect(describeTranslateError(l10n, none).details, 'refused');
    });

    test('is a network failure', () {
      expect(isNetworkFailure(_allFailed), isTrue);
    });
  });

  group('TranslateErrorView when every server failed', () {
    Future<TranslateHarness> pump(
      WidgetTester tester,
      TranslateState state, {
      Object? shown,
      bool dense = false,
      FakeOfflineTranslator? offline,
      VoidCallback? onSwitchInstance,
    }) async {
      final harness = TranslateHarness(state: state);
      await harness.pump(
        tester,
        child: TranslateErrorView(
          error: shown ?? state.error,
          dense: dense,
          onRetry: () {},
          onSwitchInstance: onSwitchInstance,
        ),
        offline: offline ?? FakeOfflineTranslator(downloaded: {'fr'}),
      );
      await tester.pump();
      return harness;
    }

    double top(WidgetTester tester, String key) =>
        tester.getTopLeft(find.byKey(Key(key))).dy;
    double left(WidgetTester tester, String key) =>
        tester.getTopLeft(find.byKey(Key(key))).dx;

    testWidgets('offers the device, another engine and another server, in '
        'that order', (tester) async {
      final harness = await pump(
        tester,
        _failed(_allFailed),
        onSwitchInstance: () {},
      );

      expect(find.text(l10n.translateErrorTitleAllServers), findsOneWidget);
      expect(
        find.text(l10n.translateErrorAllServersFailed(2, 'Google')),
        findsOneWidget,
      );
      expect(find.text(l10n.translateUseOffline), findsOneWidget);
      expect(find.text(l10n.translateErrorTryAnotherEngine), findsOneWidget);
      expect(find.text(l10n.translateErrorChooseAnotherServer), findsOneWidget);
      // The device's engine comes first, above the others.
      expect(
        top(tester, 'translate_offline_use'),
        lessThan(top(tester, 'translate_error_another_engine')),
      );
      expect(
        left(tester, 'translate_error_another_engine'),
        lessThan(left(tester, 'translate_error_another_server')),
      );
      expect(
        left(tester, 'translate_error_another_server'),
        lessThan(left(tester, 'translate_error_retry')),
      );
      expect(
        tester.widget(find.byKey(const Key('translate_error_retry'))),
        isA<TextButton>(),
      );
      // Nothing that would only try one more failing server.
      expect(
        find.byKey(const Key('translate_error_next_instance')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('translate_error_switch_instance')),
        findsNothing,
      );
      expect(find.byKey(const Key('translate_error_fix')), findsNothing);

      await tester.tap(find.byKey(const Key('translate_offline_use')));
      verify(() => harness.translate.selectEngine(_offline)).called(1);
    });

    testWidgets('"Choose another server" opens the server settings', (
      tester,
    ) async {
      final harness = await pump(tester, _failed(_allFailed));
      await tester.tap(find.byKey(const Key('translate_error_another_server')));
      verify(() => harness.router.push<void>(AppRoutes.instances)).called(1);
    });

    testWidgets('"Try another engine" opens the engine picker and switches '
        'nothing', (tester) async {
      final harness = await pump(tester, _failed(_allFailed));
      await tester.tap(find.byKey(const Key('translate_error_another_engine')));
      await tester.pumpAndSettle();

      expect(find.byType(EngineSheet), findsOneWidget);
      verify(harness.translate.loadDeferredEngines).called(1);
      verifyNever(() => harness.translate.selectEngine(any()));
    });

    testWidgets('offers the download when the pair is not on the device', (
      tester,
    ) async {
      await pump(tester, _failed(_allFailed), offline: FakeOfflineTranslator());
      expect(find.byKey(const Key('translate_offline_download')), findsOne);
      expect(
        top(tester, 'translate_offline_download'),
        lessThan(top(tester, 'translate_error_another_engine')),
      );
    });

    testWidgets('leaves out "Try another engine" without another engine', (
      tester,
    ) async {
      await pump(tester, _failed(_allFailed, engines: const [google]));
      expect(
        find.byKey(const Key('translate_error_another_engine')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('translate_error_another_server')),
        findsOneWidget,
      );
    });

    testWidgets('offline, only the device and Retry remain', (tester) async {
      deviceOfflineCheck = () async => true;
      await pump(tester, _failed(_allFailed));
      await tester.pump();

      expect(find.text(l10n.translateErrorTitleOffline), findsOneWidget);
      expect(find.byKey(const Key('translate_offline_use')), findsOneWidget);
      expect(
        find.byKey(const Key('translate_error_another_engine')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('translate_error_another_server')),
        findsNothing,
      );
      expect(find.byKey(const Key('translate_error_retry')), findsOneWidget);
    });

    testWidgets('a compare card keeps it short', (tester) async {
      await pump(tester, _failed(_allFailed), dense: true);
      expect(
        find.text(l10n.translateErrorAllServersFailed(2, 'Google')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('translate_error_another_engine')),
        findsNothing,
      );
      expect(find.byKey(const Key('translate_offline_use')), findsNothing);
    });

    testWidgets("another screen's error gets the settings shortcut", (
      tester,
    ) async {
      await pump(
        tester,
        _failed(const MozhiApiException('refused')),
        shown: _allFailed,
      );
      expect(
        find.byKey(const Key('translate_error_another_server')),
        findsNothing,
      );
      expect(find.byKey(const Key('translate_error_fix')), findsOneWidget);
    });
  });

  group('when the servers could not detect the source language', () {
    const undetected = SourceLanguageRequiredException(
      engineId: 'ai:gemma',
      cause: _allFailed,
    );

    test('says the servers failed and asks for the language', () {
      final info = describeTranslateError(l10n, undetected);
      expect(info.message, l10n.translateErrorDetectionServersFailed);
      expect(info.message, isNot(contains('500')));
      expect(info.title, l10n.translateErrorTitleAllServers);
      expect(info.chooseSourceLanguage, isTrue);
      expect(info.fix, TranslateErrorFix.none);
      expect(
        info.details,
        startsWith(
          l10n.translateErrorServersTried(
            'mozhi.one.example, mozhi.two.example',
          ),
        ),
      );
      expect(info.details, isNot(contains('secret')));
    });

    test('other detection failures keep their wording', () {
      final info = describeTranslateError(
        l10n,
        const SourceLanguageRequiredException(
          cause: MozhiApiException('Connection refused'),
        ),
      );
      expect(info.message, l10n.translateErrorSourceLanguageRequired);
      expect(info.title, l10n.translateErrorTitleLanguage);
    });

    testWidgets('offers the language and Retry', (tester) async {
      var chosen = 0;
      var retried = 0;
      final harness = TranslateHarness(state: _failed(undetected));
      await harness.pump(
        tester,
        child: TranslateErrorView(
          error: undetected,
          onRetry: () => retried++,
          onChooseSourceLanguage: () => chosen++,
        ),
        offline: FakeOfflineTranslator(downloaded: {'fr'}),
      );
      await tester.pump();
      expect(find.text(l10n.translateErrorTitleAllServers), findsOneWidget);
      expect(
        find.text(l10n.translateErrorDetectionServersFailed),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('translate_error_choose_source')));
      await tester.tap(find.byKey(const Key('translate_error_retry')));
      expect((chosen, retried), (1, 1));
    });
  });
}
