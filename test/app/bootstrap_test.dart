import 'dart:async';
import 'dart:ui';

import 'package:bloc/bloc.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mozhi/app/app_dependencies.dart';
import 'package:mozhi/app/fallback_key_value_store.dart';
import 'package:mozhi/app/third_party_licenses.dart';
import 'package:mozhi/bootstrap.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/core/network/network_session.dart';
import 'package:mozhi/core/on_device_ml.dart';
import 'package:mozhi/core/widgets/focus_ring.dart';
import 'package:mozhi/l10n/bundled_localizations_io.dart';
import 'package:mozhi/l10n/gen/app_localizations_ja.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/data/unavailable_offline_translator.dart';
import 'package:mozhi/on_device_ai/data/on_device_ai.dart';
import 'package:mozhi/settings/data/settings_repository.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:mozhi/usage/data/usage_tracker.dart';
import 'package:translation_repository/translation_repository.dart';

import '../on_device_ai/data/helpers.dart';
import 'mocks.dart';

/// A [MemoryStore] whose reads wait for [gate].
class _GatedStore extends MemoryStore {
  final gate = Completer<void>();
  int reads = 0;

  @override
  Future<String?> read(String key) async {
    reads++;
    await gate.future;
    return await super.read(key);
  }
}

class _Counter extends Cubit<int> {
  new() : super(0);

  void increment() => emit(state + 1);
  void fail() => addError(StateError('boom'), StackTrace.current);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('createDependencies', () {
    test('loads default settings from empty stores', () async {
      final dependencies = await createDependencies(
        prefs: MemoryStore(),
        secrets: MemoryStore(),
      );

      expect(dependencies.settings, const AppSettings());
      expect(
        dependencies.translationRepository.instances,
        MozhiInstance.publicInstances,
      );
      expect(dependencies.translationRepository.providers, isEmpty);
      expect(dependencies.secretsInMemory, isFalse);
    });

    test('creates the app-wide services on the preferences', () async {
      final prefs = MemoryStore();
      final dependencies = await createDependencies(
        prefs: prefs,
        secrets: MemoryStore(),
      );

      expect(dependencies.preferences, same(prefs));
      // The build's engine (Bergamot), which a desktop test host cannot
      // run: without path_provider it falls back to the unavailable one.
      expect(dependencies.offlineTranslator.isAvailable, isFalse);
      expect(
        dependencies.offlineTranslator,
        isA<UnavailableOfflineTranslator>(),
      );
      expect(dependencies.translationRepository.hasOfflineEngine, isFalse);
      expect(dependencies.speechInputService, isNotNull);

      await dependencies.usageTracker.record('p', 4, 8);
      expect(prefs.values.keys, contains(UsageTracker.storageKey));
      await dependencies.usageTracker.dispose();
      await dependencies.speechInputService.dispose();
    });

    test('keeps the read-aloud settings across restarts', () async {
      final prefs = MemoryStore();
      const voice = DeviceVoice(name: 'Amélie', locale: 'fr-CA');
      final first = await createDependencies(
        prefs: prefs,
        secrets: MemoryStore(),
      );
      await first.speechService.setSpeechRate(0.7);
      await first.speechService.setVoice('fr', voice);
      await first.speechService.setPreferDeviceVoice(enabled: true);

      final restarted = await createDependencies(
        prefs: prefs,
        secrets: MemoryStore(),
      );
      final speech = restarted.speechService;

      expect(
        await speech.loadSettings(),
        const SpeechSettings(rate: 0.7, voices: {'fr': voice}),
      );
      expect(await speech.loadPreferDeviceVoice(), isTrue);
      expect(prefs.values.keys, contains(SpeechService.settingsKey));
    });

    test('hands the offline translator to the repository', () async {
      final offline = FakeOfflineTranslator();
      final dependencies = await createDependencies(
        prefs: MemoryStore(),
        secrets: MemoryStore(),
        offlineTranslator: offline,
      );

      expect(dependencies.offlineTranslator, same(offline));
      expect(dependencies.translationRepository.hasOfflineEngine, isFalse);
    });

    test('configures the repository from the saved settings', () async {
      final prefs = MemoryStore();
      final secrets = MemoryStore();
      const instance = MozhiInstance(url: 'http://mozhi.lan:3000');
      const provider = AiProviderConfig(
        id: 'ollama',
        name: 'Ollama',
        provider: LlmProvider.ollama,
        baseUrl: 'http://pc.lan:11434',
        model: 'qwen3',
      );
      await SettingsRepository(
        prefs: prefs,
        secrets: secrets,
      ).save(const AppSettings(instances: [instance], providers: [provider]));

      final dependencies = await createDependencies(
        prefs: prefs,
        secrets: secrets,
      );

      expect(dependencies.settings.instances, const [instance]);
      expect(dependencies.translationRepository.instances, const [instance]);
      expect(dependencies.translationRepository.providers, const [provider]);
      await dependencies.settingsRepository.save(dependencies.settings);
    });

    test('adds on-device AI: its providers and its clients', () async {
      final engine = FakeLlamaEngine();
      final onDeviceAi = OnDeviceAi(
        models: FakeOnDeviceModels(assistantModel: 'gemma'),
        engine: engine,
      );
      addTearDown(onDeviceAi.dispose);
      final dependencies = await createDependencies(
        prefs: MemoryStore(),
        secrets: MemoryStore(),
        onDeviceAi: (_) async => onDeviceAi,
      );

      expect(dependencies.onDeviceAi, same(onDeviceAi));
      final repository = dependencies.translationRepository;
      expect(repository.providers, onDeviceAi.providers);
      final engines = await repository.getEngines();
      final gemma = engines.singleWhere((e) => e.id == 'ai:device-gemma');
      expect(repository.destinationOf(gemma.id), const OnDeviceDestination());
      // The repository's client for it runs in the app.
      expect(await repository.warmUp(gemma), isTrue);
      expect(engine.loads.single.$1, '/m/gemma');
    });

    test('has no on-device AI where it cannot run', () async {
      final dependencies = await createDependencies(
        prefs: MemoryStore(),
        secrets: MemoryStore(),
      );
      expect(dependencies.onDeviceAi, isNull);
    });
  });

  group('createDependencies network', () {
    late NetworkSession previous;

    setUp(() => previous = NetworkSession.current);
    tearDown(() => NetworkSession.current = previous);

    test('builds the session from the saved proxy', () async {
      final prefs = MemoryStore();
      final secrets = MemoryStore();
      await SettingsRepository(
        prefs: prefs,
        secrets: secrets,
      ).save(const AppSettings(httpProxy: '127.0.0.1:8118'));
      String? proxy;

      final dependencies = await createDependencies(
        prefs: prefs,
        secrets: secrets,
        network: (value) {
          proxy = value;
          return NetworkSession(proxy: value);
        },
      );

      expect(proxy, '127.0.0.1:8118');
      expect(dependencies.network.proxy, '127.0.0.1:8118');
      expect(NetworkSession.current, same(dependencies.network));
    });

    test('defaults to a session without a proxy', () async {
      final dependencies = await createDependencies(
        prefs: MemoryStore(),
        secrets: MemoryStore(),
      );

      expect(dependencies.network.hasProxy, isFalse);
      expect(NetworkSession.current, same(dependencies.network));
    });

    test('every repository client uses the session client', () async {
      final requests = <http.BaseRequest>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response('{"fiberversion":"v2","goversion":"go1"}', 200);
      });

      final dependencies = await createDependencies(
        prefs: MemoryStore(),
        secrets: MemoryStore(),
        network: (proxy) => NetworkSession(proxy: proxy, httpClient: client),
      );
      await dependencies.translationRepository.pingInstance(
        const MozhiInstance(url: 'https://mozhi.example'),
      );
      await expectLater(
        dependencies.translationRepository.pingInstance(
          const MozhiInstance(url: 'http://mozhi.example'),
        ),
        throwsA(
          isA<MozhiApiException>().having(
            (e) => e.message,
            'message',
            startsWith('Use https for public servers'),
          ),
        ),
      );

      expect(requests.map((r) => r.url.toString()), [
        'https://mozhi.example/api/version',
      ]);
    });
  });

  group('createDependencies without stores', () {
    test('falls back to memory when secure storage is missing', () async {
      final dependencies = await createDependencies(prefs: MemoryStore());

      final repository = dependencies.settingsRepository;
      await repository.secrets.write('apikey.x', 'secret');
      expect(await repository.secrets.read('apikey.x'), 'secret');
      expect(dependencies.secrets, isA<FallbackKeyValueStore>());
      expect(dependencies.secretsInMemory, isTrue);
    });

    test('keeps iOS keys on this device', () {
      expect(
        appSecureStorage.iOptions.toMap()['accessibility'],
        KeychainAccessibility.unlocked_this_device.name,
      );
    });

    test('keeps web secrets for the session only', () {
      expect(appSecureStorage.webOptions.useSessionStorage, isTrue);
      expect(
        appSecureStorage.mOptions.toMap()['usesDataProtectionKeychain'],
        'false',
      );
    });
  });

  group('createDependencies startup', () {
    const secureStorage = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late List<String> secureReads;

    setUp(() {
      secureReads = [];
      messenger.setMockMethodCallHandler(secureStorage, (call) async {
        if (call.method == 'read') {
          secureReads.add((call.arguments as Map)['key'] as String);
        }
        return null;
      });
    });
    tearDown(() => messenger.setMockMethodCallHandler(secureStorage, null));

    test('starts the offline speech and the secure-storage probe while the '
        'settings are read', () async {
      final prefs = _GatedStore();
      var speechStarted = false;

      final loading = createDependencies(
        prefs: prefs,
        offlineTranslator: FakeOfflineTranslator(),
        offlineSpeech: (_) async {
          speechStarted = true;
          return null;
        },
      );
      await pumpEventQueue();

      expect(prefs.reads, 1);
      expect(speechStarted, isTrue);
      expect(secureReads, [FallbackKeyValueStore.probeKey]);

      prefs.gate.complete();
      final dependencies = await loading;
      expect(dependencies.secretsInMemory, isFalse);
      expect(secureReads, contains(SettingsRepository.instanceCredentialsKey));
    });

    test('loads the texts of the app language (web)', () async {
      bundledLocalizations = (_) => null;
      resetLoadedAppLocalizations();
      addTearDown(() {
        bundledLocalizations = bundledAppLocalizations;
        resetLoadedAppLocalizations();
      });
      final prefs = MemoryStore();
      await SettingsRepository(
        prefs: prefs,
        secrets: MemoryStore(),
      ).save(const AppSettings(appLocale: 'ja'));

      await createDependencies(prefs: prefs, secrets: MemoryStore());

      expect(
        lookupAppLocalizations(const Locale('ja')),
        isA<AppLocalizationsJa>(),
      );
    });

    test('probes a given fallback store', () async {
      final dependencies = await createDependencies(
        prefs: MemoryStore(),
        secrets: FallbackKeyValueStore(SecureStore(appSecureStorage)),
      );

      expect(secureReads.first, FallbackKeyValueStore.probeKey);
      expect(dependencies.secretsInMemory, isFalse);
    });
  });

  group('AppDependencies.secretsInMemory', () {
    test('is false while secure storage works', () async {
      final dependencies = await createDependencies(
        prefs: MemoryStore(),
        secrets: FallbackKeyValueStore(MemoryStore()),
      );

      expect(dependencies.secretsInMemory, isFalse);
    });
  });

  group('bootstrap', () {
    testWidgets('runs the built widget with the dependencies', (tester) async {
      LicenseRegistry.reset();
      resetThirdPartyLicensesForTesting();
      addTearDown(LicenseRegistry.reset);
      final flutterOnError = FlutterError.onError;
      final platformOnError = PlatformDispatcher.instance.onError;
      final observer = Bloc.observer;
      addTearDown(() {
        PlatformDispatcher.instance.onError = platformOnError;
        Bloc.observer = observer;
      });
      // The real engine loads its catalog with compute(), which never
      // completes under testWidgets' fake async.
      final dependencies = await createDependencies(
        prefs: MemoryStore(),
        secrets: MemoryStore(),
        offlineTranslator: FakeOfflineTranslator(),
      );
      AppDependencies? received;

      await bootstrap((deps) {
        received = deps;
        return const Directionality(
          textDirection: TextDirection.ltr,
          child: Text('booted'),
        );
      }, dependencies: () async => dependencies);
      final onError = FlutterError.onError;
      final previousPresentError = FlutterError.presentError;
      final presented = <FlutterErrorDetails>[];
      FlutterError.presentError = presented.add;
      onError?.call(FlutterErrorDetails(exception: StateError('build')));
      FlutterError.presentError = previousPresentError;
      final handled = PlatformDispatcher.instance.onError?.call(
        StateError('uncaught'),
        StackTrace.current,
      );
      FlutterError.onError = flutterOnError;
      await tester.pump();

      expect(received, same(dependencies));
      expect(find.text('booted'), findsOneWidget);
      // Under the app-wide keyboard focus ring.
      expect(
        find.ancestor(
          of: find.text('booted'),
          matching: find.byType(FocusRingLayer),
        ),
        findsOneWidget,
      );
      expect(onError, isNot(same(flutterOnError)));
      expect(handled, isTrue);
      expect(presented, hasLength(1));
      expect(Bloc.observer, isA<AppBlocObserver>());

      // The ML Kit notice only in the Play variant; the offline engine's
      // notices always.
      final packages = await tester.runAsync(
        () async => {
          for (final entry in await LicenseRegistry.licenses.toList())
            ...entry.packages,
        },
      );
      expect(packages, contains(bergamotEngineLicensePackage));
      expect(packages?.contains(mlKitLicensePackage), mlKitIncluded);
    });
  });

  group('enableWebSemantics', () {
    int handles() => SemanticsBinding.instance.debugOutstandingSemanticsHandles;

    testWidgets('turns the accessibility tree on in a browser', (tester) async {
      final before = handles();

      final handle = enableWebSemantics(isWeb: true);

      expect(handle, isNotNull);
      expect(handles(), before + 1);
      expect(SemanticsBinding.instance.semanticsEnabled, isTrue);
      handle!.dispose();
      expect(handles(), before);
    });

    testWidgets('leaves it to the platform elsewhere', (tester) async {
      final before = handles();
      expect(enableWebSemantics(isWeb: false), isNull);
      // Tests are not a browser.
      expect(enableWebSemantics(), isNull);
      expect(handles(), before);
    });
  });

  group('AppBlocObserver', () {
    test('logs changes and errors without throwing', () async {
      final previous = Bloc.observer;
      Bloc.observer = const AppBlocObserver();
      addTearDown(() => Bloc.observer = previous);

      final cubit = _Counter()
        ..increment()
        ..fail();
      expect(cubit.state, 1);
      await cubit.close();
    });

    test('logs type names only, never state contents', () {
      final cubit = _Counter();
      addTearDown(cubit.close);
      const change = Change<Object>(
        currentState: 'sk-secret-key',
        nextState: 'Hola, ¿qué tal?',
      );

      final line = AppBlocObserver.describeChange(cubit, change);

      expect(line, 'onChange(_Counter: String -> String)');
      expect(line, isNot(contains('sk-secret')));
      expect(line, isNot(contains('Hola')));
    });
  });
}
