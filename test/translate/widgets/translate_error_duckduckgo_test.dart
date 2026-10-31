import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/fake_offline.dart';
import '../helpers/helpers.dart';

const _one = MozhiInstance(url: 'https://mozhi.one.example');
const _two = MozhiInstance(url: 'https://mozhi.two.example');

/// What today's public servers answer for Google.
const _rateLimited = MozhiApiException(
  'request failed with status code: 429',
  statusCode: 500,
);

AllInstancesFailedException _failedWith(
  List<MozhiApiException> failures, {
  TranslationEngine engine = google,
}) => AllInstancesFailedException.from(
  failures.last,
  engine: engine,
  instances: const [_one, _two],
  failures: failures,
);

final AllInstancesFailedException _googleRateLimited = _failedWith(const [
  _rateLimited,
  MozhiApiException('invalid json', statusCode: 500),
]);

final AllInstancesFailedException _googleFailed = _failedWith(const [
  MozhiApiException('invalid json', statusCode: 500),
  MozhiApiException('invalid json', statusCode: 500),
]);

final _offline = TranslationEngine.offline();

/// A failed German -> English translation with [engine] with [error].
TranslateState _failed(Object error, {TranslationEngine engine = google}) =>
    readyState(
      engine: engine,
      source: german,
      input: 'Hallo Welt',
      status: TranslateStatus.failure,
    ).copyWith(engines: [google, deepl, _offline], error: () => error);

void main() {
  setUpAll(registerTranslateFallbacks);

  setUp(() => deviceOfflineCheck = () async => false);

  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  group('describeTranslateError when the engine limits the servers', () {
    test('says so in plain words when any server was rate limited', () {
      final info = describeTranslateError(l10n, _googleRateLimited);
      expect(info.message, l10n.translateErrorAllServersRateLimited('Google'));
      expect(
        info.message,
        'Google is limiting requests from the volunteer servers right now. '
        'This usually passes after a while.',
      );
      expect(info.title, l10n.translateErrorTitleAllServers);
      expect(info.fix, TranslateErrorFix.instances);
    });

    test("never shows the servers' own text or addresses in the message", () {
      final error = _failedWith(const [
        MozhiApiException(
          'Post "https://translate.google.com/?q=Hallo%20Welt": '
          'instance has been rate limited',
          statusCode: 500,
        ),
      ]);
      final info = describeTranslateError(l10n, error);
      expect(info.message, l10n.translateErrorAllServersRateLimited('Google'));
      expect(info.message, isNot(contains('http')));
      expect(info.message, isNot(contains('Hallo')));
      expect(info.message, isNot(contains('429')));
    });

    test('names the engine that limits them', () {
      final error = _failedWith(const [_rateLimited], engine: deepl);
      expect(
        describeTranslateError(l10n, error).message,
        l10n.translateErrorAllServersRateLimited('DeepL'),
      );
    });

    test('keeps the usual message for other failures', () {
      expect(
        describeTranslateError(l10n, _googleFailed).message,
        l10n.translateErrorAllServersFailed(2, 'Google'),
      );
    });
  });

  group('"Use DuckDuckGo when Google fails"', () {
    Future<TranslateHarness> pump(
      WidgetTester tester,
      TranslateState state, {
      AppSettings settings = const AppSettings(),
      bool dense = false,
    }) async {
      final harness = TranslateHarness(state: state, settings: settings);
      when(harness.translate.useDuckDuckGoWhenGoogleFails)
          .thenAnswer((_) async {});
      await harness.pump(
        tester,
        child: TranslateErrorView(
          error: state.error,
          dense: dense,
          onRetry: () {},
        ),
        offline: FakeOfflineTranslator(downloaded: {'de'}),
      );
      await tester.pump();
      return harness;
    }

    const action = Key('translate_error_use_duckduckgo');

    testWidgets('is offered with the other ways out when Google was rate '
        'limited on every server', (tester) async {
      await pump(tester, _failed(_googleRateLimited));

      expect(
        find.text(l10n.translateErrorAllServersRateLimited('Google')),
        findsOneWidget,
      );
      expect(find.byKey(action), findsOneWidget);
      expect(find.text('Use DuckDuckGo when Google fails'), findsOneWidget);
      expect(
        find.byKey(const Key('translate_error_another_engine')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('translate_error_another_server')),
        findsOneWidget,
      );
      // A small text button, not the main action.
      expect(tester.widget(find.byKey(action)), isA<TextButton>());
    });

    testWidgets('turns the fallback on and retries with one tap', (
      tester,
    ) async {
      final harness = await pump(tester, _failed(_googleFailed));
      await tester.tap(find.byKey(action));
      verify(harness.translate.useDuckDuckGoWhenGoogleFails).called(1);
    });

    testWidgets('is left out while the fallback is on already', (tester) async {
      await pump(
        tester,
        _failed(_googleFailed),
        settings: const AppSettings(fallbackToDuckDuckGo: true),
      );
      expect(find.byKey(action), findsNothing);
    });

    testWidgets('is left out in Offline only', (tester) async {
      await pump(
        tester,
        _failed(_googleFailed),
        settings: const AppSettings(privacyMode: PrivacyMode.offlineOnly),
      );
      expect(find.byKey(action), findsNothing);
    });

    testWidgets('is left out for another engine', (tester) async {
      await pump(
        tester,
        _failed(
          _failedWith(const [_rateLimited], engine: deepl),
          engine: deepl,
        ),
      );
      expect(find.byKey(action), findsNothing);
    });

    testWidgets('is left out when no server could be reached', (tester) async {
      await pump(
        tester,
        _failed(
          _failedWith(const [
            MozhiApiException('Connection refused'),
            MozhiApiException('Connection refused'),
          ]),
        ),
      );
      expect(find.byKey(action), findsNothing);
    });

    testWidgets('is left out on a compare card', (tester) async {
      await pump(tester, _failed(_googleFailed), dense: true);
      expect(find.byKey(action), findsNothing);
    });

    testWidgets('is left out while the device is offline', (tester) async {
      deviceOfflineCheck = () async => true;
      await pump(tester, _failed(_googleFailed));
      await tester.pump();
      expect(find.byKey(action), findsNothing);
    });
  });
}
