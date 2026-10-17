import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/core/widgets/consent_prompt.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

class _MockSettingsCubit extends MockCubit<AppSettings>
    implements SettingsCubit;

class _MockRepository extends Mock implements TranslationRepository;

class _MockGoRouter extends Mock implements GoRouter;

class _FakeOfflineTranslator extends Fake implements OfflineTranslator {
  new({this.isAvailable = true});

  @override
  final bool isAvailable;

  @override
  Set<String> get supportedLanguages => const {'en', 'de', 'fr'};
}

/// A cubit whose state is a [ConsentRequiredException] (or null).
class _ConsentCubit extends Cubit<ConsentRequiredException?> {
  new() : super(null);

  void fail(ConsentRequiredException consent) => emit(consent);
}

const _public = PublicInstanceDestination(
  'mozhi.example.org',
  engine: 'google',
);
const _pairConsent = ConsentRequiredException(
  kind: ConsentKind.pair,
  destination: _public,
  engineId: 'mozhi:google',
  source: 'de',
  target: 'en',
);
const _cloudConsent = ConsentRequiredException(
  kind: ConsentKind.cloudProvider,
  destination: CloudProviderDestination('Claude', host: 'api.anthropic.com'),
  engineId: 'ai:claude',
  source: 'de',
  target: 'en',
);
const _offlineOnlyConsent = ConsentRequiredException(
  kind: ConsentKind.offlineOnly,
  destination: _public,
  engineId: 'mozhi:google',
  source: 'de',
  target: 'en',
);
const _listConsent = ConsentRequiredException(
  kind: ConsentKind.pair,
  destination: PublicInstanceDestination('mozhi.example.org'),
  engineId: 'mozhi:',
);

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  late _MockSettingsCubit settings;
  late _MockRepository repository;
  late _MockGoRouter router;

  setUpAll(() => registerFallbackValue(_pairConsent));

  setUp(() {
    settings = _MockSettingsCubit();
    repository = _MockRepository();
    router = _MockGoRouter();
    when(() => settings.state).thenReturn(const AppSettings());
    when(() => repository.instances)
        .thenReturn(const [MozhiInstance(url: 'https://mozhi.example.org')]);
  });

  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(400, 800),
    OfflineTranslator? offline,
  }) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      InheritedGoRouter(
        goRouter: router,
        child: MultiRepositoryProvider(
          providers: [
            RepositoryProvider<TranslationRepository>.value(value: repository),
            if (offline != null)
              RepositoryProvider<OfflineTranslator>.value(value: offline),
          ],
          child: BlocProvider<SettingsCubit>.value(
            value: settings,
            child: MaterialApp(
              theme: ThemeData(useMaterial3: true),
              localizationsDelegates: appLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(body: Center(child: child)),
            ),
          ),
        ),
      ),
    );
  }

  /// A button that runs [action] with its context and keeps the result.
  Widget opener(Future<bool> Function(BuildContext context) action) => Builder(
    builder: (context) => TextButton(
      onPressed: () async => _result = await action(context),
      child: const Text('open'),
    ),
  );

  group('describing destinations', () {
    test('upstream engine names', () {
      expect(upstreamEngineName('google'), 'Google');
      expect(upstreamEngineName('deepl'), 'DeepL');
      expect(upstreamEngineName('duckduckgo'), 'DuckDuckGo');
      expect(upstreamEngineName('yandex'), 'Yandex');
      expect(upstreamEngineName('libre'), 'LibreTranslate');
      expect(upstreamEngineName('reverso'), 'Reverso');
      expect(upstreamEngineName('mymemory'), 'MyMemory');
      expect(upstreamEngineName('bing'), 'Bing');
      expect(upstreamEngineName('other'), 'Other');
      expect(upstreamEngineName(''), '');
    });

    test('labels', () {
      expect(destinationLabel(l10n, const OnDeviceDestination()), 'On device');
      expect(
        destinationLabel(l10n, const SelfHostedDestination('192.168.1.2')),
        'your server (192.168.1.2)',
      );
      expect(
        destinationLabel(
          l10n,
          const SelfHostedDestination('192.168.1.2'),
          engineId: 'mozhi:deepl',
        ),
        'DeepL via 192.168.1.2',
      );
      expect(destinationLabel(l10n, _public), 'Google via mozhi.example.org');
      expect(
        destinationLabel(l10n, const PublicInstanceDestination('lt.example')),
        'lt.example',
      );
      expect(
        destinationLabel(l10n, const PublicInstanceDestination('')),
        'a public server',
      );
      expect(
        destinationLabel(l10n, const CloudProviderDestination('Claude')),
        'Claude',
      );
    });

    test('descriptions say who can read the text', () {
      expect(
        destinationDescription(l10n, const OnDeviceDestination()),
        contains('isn’t sent anywhere'),
      );
      expect(
        destinationDescription(l10n, const SelfHostedDestination('nas')),
        contains('your own server at nas'),
      );
      expect(
        destinationDescription(
          l10n,
          const SelfHostedDestination('nas'),
          engineId: 'mozhi:google',
        ),
        contains('passes it on to Google'),
      );
      expect(
        destinationDescription(l10n, _public),
        allOf(contains('mozhi.example.org'), contains('Google')),
      );
      expect(
        destinationDescription(l10n, const PublicInstanceDestination('')),
        contains('a public server'),
      );
      expect(
        destinationDescription(
          l10n,
          const PublicInstanceDestination('', engine: 'google'),
        ),
        contains('a public server'),
      );
      expect(
        destinationDescription(l10n, const CloudProviderDestination('Claude')),
        contains('privacy policy'),
      );
    });

    test('icons', () {
      expect(destinationIcon(const OnDeviceDestination()), Icons.phone_android);
      expect(
        destinationIcon(const SelfHostedDestination('nas')),
        Icons.dns_outlined,
      );
      expect(destinationIcon(_public), Icons.public);
      expect(
        destinationIcon(const CloudProviderDestination('Claude')),
        Icons.cloud_outlined,
      );
    });

    test('pairs and the Always label', () {
      expect(consentPairLabel(l10n, 'de', 'en'), 'German → English');
      expect(consentPairLabel(l10n, 'auto', 'en'), 'Detect language → English');
      expect(
        consentAlwaysLabel(l10n, _pairConsent),
        'Always for German → English',
      );
      expect(
        consentAlwaysLabel(
          l10n,
          const ConsentRequiredException(
            kind: ConsentKind.pair,
            destination: _public,
            engineId: 'mozhi:google',
            source: 'ja',
            target: 'ja',
          ),
        ),
        'Always for Japanese',
      );
      expect(
        consentAlwaysLabel(
          l10n,
          const ConsentRequiredException(
            kind: ConsentKind.pair,
            destination: _public,
            engineId: 'ai:claude',
            source: 'auto',
            target: 'auto',
          ),
        ),
        'Always',
      );
      expect(
        consentAlwaysLabel(
          l10n,
          const ConsentRequiredException(
            kind: ConsentKind.pair,
            destination: _public,
            engineId: 'mozhi:google',
            source: 'auto',
            target: 'fr',
          ),
        ),
        'Always into French',
      );
      expect(isListConsent(_listConsent), isTrue);
      expect(isListConsent(_pairConsent), isFalse);
    });

    test('one-line messages', () {
      expect(
        consentMessage(l10n, _offlineOnlyConsent),
        l10n.commonConsentErrorOfflineOnly,
      );
      expect(consentMessage(l10n, _cloudConsent), contains('Claude'));
      expect(
        consentMessage(l10n, _pairConsent),
        contains('Google via mozhi.example.org'),
      );
    });
  });

  group('grantConsent', () {
    bool grant(ConsentRequiredException consent, ConsentChoice choice) =>
        grantConsent(
          settings: settings,
          repository: repository,
          consent: consent,
          choice: choice,
          requests: 3,
        );

    test('once lets the request through without saving anything', () {
      expect(grant(_pairConsent, ConsentChoice.once), isTrue);
      verify(() => repository.allowOnce(_pairConsent, requests: 3)).called(1);
      verifyNever(() => settings.approveNetworkPair(any()));
    });

    test('always approves the pair', () {
      expect(grant(_pairConsent, ConsentChoice.always), isTrue);
      verify(() => settings.approveNetworkPair('de>en')).called(1);
      verify(() => repository.allowOnce(_pairConsent, requests: 3)).called(1);
    });

    test('always approves an auto pair', () {
      const consent = ConsentRequiredException(
        kind: ConsentKind.pair,
        destination: _public,
        engineId: 'ai:claude',
        source: 'auto',
        target: 'auto',
      );
      grant(consent, ConsentChoice.always);
      verify(() => settings.approveNetworkPair('auto>auto')).called(1);
    });

    test('a cloud provider is consented to', () {
      expect(grant(_cloudConsent, ConsentChoice.always), isTrue);
      verify(() => settings.consentToProvider('claude')).called(1);
      verify(() => repository.allowOnce(_cloudConsent, requests: 3)).called(1);
    });

    test('a cloud consent without a provider id only lets it through', () {
      const consent = ConsentRequiredException(
        kind: ConsentKind.cloudProvider,
        destination: CloudProviderDestination('X'),
        engineId: 'x',
      );
      expect(grant(consent, ConsentChoice.always), isTrue);
      verifyNever(() => settings.consentToProvider(any()));
    });

    test('offline only cannot be granted', () {
      expect(grant(_offlineOnlyConsent, ConsentChoice.always), isFalse);
      verifyNever(() => repository.allowOnce(any()));
    });

    test('lists are allowed for the session', () {
      expect(grant(_listConsent, ConsentChoice.once), isTrue);
      verify(() => repository.allowMetadataRequests()).called(1);
    });
  });

  group('offlineOfferFor', () {
    Future<OfflineOffer?> offerIn(
      WidgetTester tester,
      ConsentRequiredException consent, {
      OfflineTranslator? offline,
    }) async {
      OfflineOffer? offer;
      await pump(
        tester,
        Builder(
          builder: (context) {
            offer = offlineOfferFor(context, consent);
            return const SizedBox();
          },
        ),
        offline: offline,
      );
      return offer;
    }

    testWidgets('none without an offline engine', (tester) async {
      expect(await offerIn(tester, _pairConsent), isNull);
      expect(
        await offerIn(
          tester,
          _pairConsent,
          offline: _FakeOfflineTranslator(isAvailable: false),
        ),
        isNull,
      );
    });

    testWidgets('none for pairs it cannot translate', (tester) async {
      const japanese = ConsentRequiredException(
        kind: ConsentKind.pair,
        destination: _public,
        engineId: 'mozhi:google',
        source: 'ja',
        target: 'en',
      );
      final offline = _FakeOfflineTranslator();
      expect(await offerIn(tester, japanese, offline: offline), isNull);
      expect(await offerIn(tester, _listConsent, offline: offline), isNull);
    });

    testWidgets('names the language to download and opens the models', (
      tester,
    ) async {
      final offer = await offerIn(
        tester,
        _pairConsent,
        offline: _FakeOfflineTranslator(),
      );
      expect(offer?.language, 'German');
      offer!.onDownload();
      verify(() => router.go(AppRoutes.offline)).called(1);
    });

    testWidgets('English only downloads English', (tester) async {
      const english = ConsentRequiredException(
        kind: ConsentKind.pair,
        destination: _public,
        engineId: 'mozhi:google',
        source: 'en',
        target: 'en',
      );
      final offer = await offerIn(
        tester,
        english,
        offline: _FakeOfflineTranslator(),
      );
      expect(offer?.language, 'English');
    });

    testWidgets('an auto source downloads the target', (tester) async {
      const auto = ConsentRequiredException(
        kind: ConsentKind.pair,
        destination: _public,
        engineId: 'mozhi:google',
        source: 'auto',
        target: 'fr',
      );
      final offer = await offerIn(
        tester,
        auto,
        offline: _FakeOfflineTranslator(),
      );
      expect(offer?.language, 'French');
    });
  });

  group('requestConsent', () {
    testWidgets('a pair: Once lets this request through (dialog)', (
      tester,
    ) async {
      await pump(
        tester,
        opener((context) => requestConsent(context, _pairConsent)),
        size: const Size(1000, 800),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.text('Send this text to Google via mozhi.example.org?'),
        findsOneWidget,
      );
      expect(find.textContaining('operator and Google'), findsOneWidget);
      expect(find.text('Always for German → English'), findsOneWidget);
      await tester.tap(find.text('Once'));
      await tester.pumpAndSettle();
      expect(_result, isTrue);
      verify(() => repository.allowOnce(_pairConsent)).called(1);
      verifyNever(() => settings.approveNetworkPair(any()));
    });

    testWidgets('a pair: Always approves it (bottom sheet on phones)', (
      tester,
    ) async {
      when(() => repository.instances).thenReturn(const [
        MozhiInstance(url: 'https://mozhi.example.org'),
        MozhiInstance(url: 'https://b.example'),
        MozhiInstance(url: 'https://c.example'),
      ]);
      await pump(
        tester,
        opener((context) => requestConsent(context, _pairConsent)),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.textContaining('the other 2 servers'), findsOneWidget);
      await tester.tap(find.text('Always for German → English'));
      await tester.pumpAndSettle();
      expect(_result, isTrue);
      verify(() => settings.approveNetworkPair('de>en')).called(1);
    });

    testWidgets('Cancel sends nothing', (tester) async {
      await pump(
        tester,
        opener((context) => requestConsent(context, _pairConsent)),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(_result, isFalse);
      verifyNever(() => repository.allowOnce(any()));
    });

    testWidgets('offers the on-device download', (tester) async {
      var downloads = 0;
      await pump(
        tester,
        opener(
          (context) => requestConsent(
            context,
            _pairConsent,
            onDownloadOffline: () => downloads++,
            offlineLanguage: 'German',
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download German for offline use'));
      await tester.pumpAndSettle();
      expect(_result, isFalse);
      expect(downloads, 1);
    });

    testWidgets('askConsent offers it when the device can translate', (
      tester,
    ) async {
      await pump(
        tester,
        opener((context) => askConsent(context, _pairConsent)),
        offline: _FakeOfflineTranslator(),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download German for offline use'));
      await tester.pumpAndSettle();
      verify(() => router.go(AppRoutes.offline)).called(1);
    });

    testWidgets('a cloud provider: Allow consents to it', (tester) async {
      await pump(
        tester,
        opener((context) => askConsent(context, _cloudConsent, requests: 4)),
        size: const Size(1000, 800),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Send your text to Claude?'), findsOneWidget);
      expect(find.textContaining('privacy policy'), findsOneWidget);
      await tester.tap(find.text('Allow'));
      await tester.pumpAndSettle();
      expect(_result, isTrue);
      verify(() => settings.consentToProvider('claude')).called(1);
      verify(() => repository.allowOnce(_cloudConsent, requests: 4)).called(1);
    });

    testWidgets('offline only: Change privacy mode opens the settings', (
      tester,
    ) async {
      await pump(
        tester,
        opener((context) => requestConsent(context, _offlineOnlyConsent)),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Offline only is on'), findsOneWidget);
      expect(find.text('Once'), findsNothing);
      await tester.tap(find.text('Change privacy mode'));
      await tester.pumpAndSettle();
      expect(_result, isFalse);
      verify(() => router.go(AppRoutes.settings)).called(1);
    });

    testWidgets('lists: Allow loads them for this session', (tester) async {
      await pump(
        tester,
        opener((context) => requestConsent(context, _listConsent)),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Connect to mozhi.example.org?'), findsOneWidget);
      expect(find.textContaining('None of your text'), findsOneWidget);
      await tester.tap(find.text('Allow'));
      await tester.pumpAndSettle();
      expect(_result, isTrue);
      verify(() => repository.allowMetadataRequests()).called(1);
    });
  });

  group('ConsentInlinePrompt', () {
    Future<int> pumpPrompt(
      WidgetTester tester,
      ConsentRequiredException consent,
    ) async {
      var granted = 0;
      await pump(
        tester,
        StatefulBuilder(
          builder: (context, _) => ConsentInlinePrompt(
            consent: consent,
            requests: 2,
            onGranted: () => granted++,
          ),
        ),
      );
      return granted;
    }

    testWidgets('a pair: Once and Always', (tester) async {
      var granted = 0;
      await pump(
        tester,
        ConsentInlinePrompt(
          consent: _pairConsent,
          requests: 2,
          onGranted: () => granted++,
        ),
      );
      expect(
        find.text(
          'Translating this needs the network. Send it to Google via '
          'mozhi.example.org?',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Once'));
      verify(() => repository.allowOnce(_pairConsent, requests: 2)).called(1);
      await tester.tap(find.text('Always for German → English'));
      verify(() => settings.approveNetworkPair('de>en')).called(1);
      expect(granted, 2);
    });

    testWidgets('a cloud provider: Allow', (tester) async {
      await pumpPrompt(tester, _cloudConsent);
      expect(find.textContaining('sends your text to Claude'), findsOneWidget);
      await tester.tap(find.text('Allow'));
      verify(() => settings.consentToProvider('claude')).called(1);
    });

    testWidgets('lists: Allow', (tester) async {
      await pumpPrompt(tester, _listConsent);
      expect(find.textContaining('Load the engines'), findsOneWidget);
      await tester.tap(find.text('Allow'));
      verify(() => repository.allowMetadataRequests()).called(1);
    });

    testWidgets('offline only: only Details', (tester) async {
      await pumpPrompt(tester, _offlineOnlyConsent);
      expect(find.text('Allow'), findsNothing);
      expect(find.text('Once'), findsNothing);
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      expect(find.text('Offline only is on'), findsOneWidget);
    });

    testWidgets('Details opens the prompt and retries once allowed', (
      tester,
    ) async {
      var granted = 0;
      await pump(
        tester,
        ConsentInlinePrompt(consent: _pairConsent, onGranted: () => granted++),
      );
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Once').last);
      await tester.pumpAndSettle();
      expect(granted, 1);

      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(granted, 1);
    });
  });

  group('DestinationChip', () {
    testWidgets('names the destination and explains it', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester, const DestinationChip(destination: _public));
      expect(find.text('Google via mozhi.example.org'), findsOneWidget);
      expect(find.byIcon(Icons.public), findsOneWidget);
      expect(
        find.bySemanticsLabel(
          'Sent to Google via mozhi.example.org. Show where your text goes',
        ),
        findsOneWidget,
      );
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));

      await tester.tap(find.byType(DestinationChip));
      await tester.pumpAndSettle();
      expect(find.text('Where your text goes'), findsOneWidget);
      expect(find.textContaining('operator and Google'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Where your text goes'), findsNothing);
      handle.dispose();
    });

    testWidgets('names the upstream engine of a self-hosted Mozhi', (
      tester,
    ) async {
      await pump(
        tester,
        const DestinationChip(
          destination: SelfHostedDestination('nas.local'),
          engineId: 'mozhi:deepl',
        ),
      );
      expect(find.text('DeepL via nas.local'), findsOneWidget);
      expect(find.byIcon(Icons.dns_outlined), findsOneWidget);
    });
  });

  group('ConsentDialogListener', () {
    testWidgets('asks for each new refusal and retries once allowed', (
      tester,
    ) async {
      final cubit = _ConsentCubit();
      addTearDown(cubit.close);
      var retried = 0;
      await pump(
        tester,
        BlocProvider.value(
          value: cubit,
          child:
              ConsentDialogListener<_ConsentCubit, ConsentRequiredException?>(
                consentOf: (state) => state,
                requestsOf: (_) => 5,
                onGranted: (_) => retried++,
                child: const SizedBox(),
              ),
        ),
      );
      cubit.fail(_pairConsent);
      await tester.pumpAndSettle();
      expect(find.text('Once'), findsOneWidget);
      await tester.tap(find.text('Once'));
      await tester.pumpAndSettle();
      expect(retried, 1);
      verify(() => repository.allowOnce(_pairConsent, requests: 5)).called(1);

      cubit.fail(_cloudConsent);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(retried, 1);
    });
  });
}

/// What the last [requestConsent] / [askConsent] returned.
bool? _result;
