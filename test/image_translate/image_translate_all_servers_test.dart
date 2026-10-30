import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/image_translate/image_translate.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:translation_repository/translation_repository.dart';

import 'helpers/helpers.dart';

const _first = MozhiInstance(url: 'https://user:secret@mozhi.one.example');
const _second = MozhiInstance(url: 'https://mozhi.two.example');

final _googleEngine = TranslationEngine.mozhi('google', 'Google');

final _allFailed = AllInstancesFailedException(
  'Post "https://translate.google.com/?q=Hola": Forbidden',
  engine: _googleEngine,
  instances: const [_first, _second],
  statusCode: 502,
);

void main() {
  setUpAll(registerImageTranslateFallbacks);

  late AppLocalizations l10n;

  setUp(() => l10n = lookupAppLocalizations(const Locale('en')));

  group('mapError', () {
    test('passes every server failing through', () {
      expect(
        ImageTranslateCubit.mapError(
          _allFailed,
          method: ImageTranslateMethodKind.mozhiLens,
        ),
        same(_allFailed),
      );
      // Also when the last server answered with a gateway timeout.
      final gateway = AllInstancesFailedException(
        'Gateway Timeout',
        engine: _googleEngine,
        instances: const [_first],
        statusCode: 504,
      );
      expect(
        ImageTranslateCubit.mapError(
          gateway,
          method: ImageTranslateMethodKind.mozhiLens,
        ),
        same(gateway),
      );
    });

    test('keeps Google sending nothing back a refused service', () {
      final empty = AllInstancesFailedException(
        TranslationRepository.imageNoResultMessage,
        engine: _googleEngine,
        instances: const [_first, _second],
        statusCode: 502,
      );
      expect(
        ImageTranslateCubit.mapError(
          empty,
          method: ImageTranslateMethodKind.mozhiLens,
        ),
        const ImageTranslateException(ImageTranslateErrorKind.serviceRefused),
      );
    });
  });

  group('ImageTranslateCubit', () {
    late MockTranslationRepository repository;

    setUp(() => repository = MockTranslationRepository());

    ImageTranslateCubit build() => ImageTranslateCubit(
      repository: repository,
      picker: FakeImagePickerService(),
      encoder: FakeImageEncoder(),
      recognizer: FakeTextRecognitionService(text: 'Hola'),
      engines: allEngines,
      providers: allProviders,
      translateEngine: deepl,
      target: french,
      slowThreshold: const Duration(minutes: 1),
    );

    blocTest<ImageTranslateCubit, ImageTranslateState>(
      'fails with the all-servers error when every server failed',
      setUp: () => when(
        () => repository.translateImage(
          any(),
          any(),
          mimeType: any(named: 'mimeType'),
          source: any(named: 'source'),
          target: any(named: 'target'),
          options: any(named: 'options'),
        ),
      ).thenThrow(_allFailed),
      build: build,
      act: (cubit) async {
        await cubit.selectMethod(mozhiMethod);
        unawaited(cubit.setImage(jpegImage));
        await cubit.translate();
      },
      verify: (cubit) {
        expect(cubit.state.status, ImageTranslateStatus.failure);
        expect(cubit.state.error, same(_allFailed));
        expect(cubit.state.offersOnDevice, isTrue);
      },
    );
  });

  group('ImageTranslateErrorView when every server failed', () {
    late ImageTranslateHarness harness;

    setUp(() => harness = ImageTranslateHarness());

    Future<({List<String> taps})> pump(
      WidgetTester tester, {
      bool onDevice = true,
    }) async {
      final taps = <String>[];
      await harness.pump(
        tester,
        Scaffold(
          body: ImageTranslateErrorView(
            error: _allFailed,
            method: ImageTranslateMethodKind.mozhiLens,
            onRetry: () => taps.add('retry'),
            onUseOnDevice: onDevice ? () => taps.add('device') : null,
          ),
        ),
      );
      return (taps: taps);
    }

    testWidgets('says so in plain words, like the translator', (tester) async {
      await pump(tester);
      expect(
        find.byKey(const Key('image_translate_error_title')),
        findsOneWidget,
      );
      expect(find.text(l10n.translateErrorTitleAllServers), findsOneWidget);
      expect(
        find.text(l10n.translateErrorAllServersFailed(2, 'Google')),
        findsOneWidget,
      );
      // No HTTP status outside the folded details.
      expect(find.textContaining('502'), findsNothing);
      expect(find.textContaining('HTTP'), findsNothing);
      expect(find.text(l10n.translateManageInstances), findsNothing);
    });

    testWidgets('offers on-device recognition, Retry and another server', (
      tester,
    ) async {
      final (:taps) = await pump(tester);
      await tester.tap(find.byKey(const Key('image_translate_use_on_device')));
      await tester.tap(find.byKey(const Key('image_translate_retry_button')));
      expect(taps, ['device', 'retry']);

      await tester.tap(find.text(l10n.translateErrorChooseAnotherServer));
      verify(() => harness.router.push<Object?>('/settings/instances'))
          .called(1);
    });

    testWidgets('without on-device recognition, Retry comes first', (
      tester,
    ) async {
      await pump(tester, onDevice: false);
      expect(
        find.byKey(const Key('image_translate_use_on_device')),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(FilledButton),
          matching: find.text(l10n.commonRetry),
        ),
        findsOneWidget,
      );
    });

    testWidgets('names the servers tried in the details, without '
        'credentials', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('translate_error_details')));
      await tester.pump();
      final details = tester
          .widget<SelectableText>(
            find.byKey(const Key('translate_error_details_text')),
          )
          .data!;
      expect(
        details,
        startsWith(
          l10n.translateErrorServersTried(
            'mozhi.one.example, mozhi.two.example',
          ),
        ),
      );
      expect(details, isNot(contains('secret')));
      expect(details, isNot(contains('Hola')));
    });

    testWidgets('other Mozhi errors keep their wording', (tester) async {
      await harness.pump(
        tester,
        const Scaffold(
          body: ImageTranslateErrorView(error: MozhiApiException('offline')),
        ),
      );
      expect(
        find.byKey(const Key('image_translate_error_title')),
        findsNothing,
      );
      expect(find.text(l10n.translateManageInstances), findsOneWidget);
    });
  });
}
