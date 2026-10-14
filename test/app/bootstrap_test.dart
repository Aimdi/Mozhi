import 'dart:ui';

import 'package:bloc/bloc.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mlkit_translator/mlkit_translator.dart';
import 'package:mozhi/app/app_dependencies.dart';
import 'package:mozhi/app/fallback_key_value_store.dart';
import 'package:mozhi/bootstrap.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/settings/data/settings_repository.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:mozhi/usage/data/usage_tracker.dart';
import 'package:translation_repository/translation_repository.dart';

import 'mocks.dart';

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
      expect(dependencies.offlineTranslator, isA<MlKitOfflineTranslator>());
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
      final flutterOnError = FlutterError.onError;
      final platformOnError = PlatformDispatcher.instance.onError;
      final observer = Bloc.observer;
      addTearDown(() {
        PlatformDispatcher.instance.onError = platformOnError;
        Bloc.observer = observer;
      });
      final dependencies = await createDependencies(
        prefs: MemoryStore(),
        secrets: MemoryStore(),
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
      expect(onError, isNot(same(flutterOnError)));
      expect(handled, isTrue);
      expect(presented, hasLength(1));
      expect(Bloc.observer, isA<AppBlocObserver>());
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
