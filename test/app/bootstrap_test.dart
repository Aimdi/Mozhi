import 'dart:ui';

import 'package:bloc/bloc.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/app/app_dependencies.dart';
import 'package:mozhi/bootstrap.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/settings/data/settings_repository.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

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
  });
}
