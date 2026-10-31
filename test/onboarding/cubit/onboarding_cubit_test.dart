import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/onboarding/cubit/onboarding_cubit.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers.dart';

void main() {
  setUpAll(registerOnboardingFallbacks);

  late MockTranslationRepository repository;
  late SettingsCubit settings;

  setUp(() {
    repository = MockTranslationRepository();
    settings = createSettings();
  });

  tearDown(() => settings.close());

  OnboardingCubit build({Duration pingTimeout = const Duration(seconds: 6)}) =>
      OnboardingCubit(
        repository: repository,
        settings: settings,
        pingTimeout: pingTimeout,
        deviceLanguages: () => const [],
      );

  void stubPing(String url, Future<Duration> Function() answer) {
    when(
      () => repository.pingInstance(
        any(that: isA<MozhiInstance>().having((i) => i.url, 'url', url)),
        engine: any(named: 'engine'),
      ),
    ).thenAnswer((_) => answer());
  }

  /// [url] answers without translating (an HTTP 500, as when Google fails
  /// on that server).
  void stubNoTranslation(String url, {String message = 'Post: 429'}) =>
      stubPing(
        url,
        () => Future.error(
          InstanceDoesNotTranslateException(
            message,
            engine: 'google',
            statusCode: 500,
          ),
        ),
      );

  void stubLatencies(Map<String, int?> millis) {
    for (final MapEntry(key: url, value: ms) in millis.entries) {
      stubPing(
        url,
        () => ms == null
            ? Future.error(const MozhiApiException('down'))
            : Future.value(Duration(milliseconds: ms)),
      );
    }
  }

  group('onboardingErrorMessage', () {
    test('describes known errors', () {
      expect(onboardingErrorMessage(const MozhiApiException('m')), 'm');
      expect(onboardingErrorMessage(const LlmApiException('l')), 'l');
      expect(
        onboardingErrorMessage(const LlmApiException('bad', statusCode: 401)),
        '401: bad',
      );
      expect(onboardingErrorMessage(const FormatException('f')), 'f');
      expect(onboardingErrorMessage(StateError('s')), 'Bad state: s');
    });
  });

  group('devices without an on-device engine', () {
    OnboardingCubit web() => OnboardingCubit(
      repository: repository,
      settings: settings,
      onDevice: false,
    );

    test('skip the privacy step', () {
      final cubit = web();
      expect(cubit.state.onDevice, isFalse);
      expect(cubit.state.steps, [
        OnboardingStep.welcome,
        OnboardingStep.languages,
        OnboardingStep.service,
      ]);
      cubit.next();
      expect(cubit.state.step, OnboardingStep.languages);
      cubit.goTo(OnboardingStep.privacy);
      expect(cubit.state.step, OnboardingStep.languages);
      cubit.back();
      expect(cubit.state.step, OnboardingStep.welcome);
    });

    test('select Online on arriving at the service step, once', () {
      final cubit = web()..next();
      expect(settings.state.privacyMode, PrivacyMode.offlineFirst);
      cubit.next();
      expect(cubit.state.isLastStep, isTrue);
      expect(settings.state.privacyMode, PrivacyMode.online);

      cubit.setAskBeforeSending(ask: true);
      expect(settings.state.privacyMode, PrivacyMode.offlineFirst);
      cubit
        ..back()
        ..next();
      expect(settings.state.privacyMode, PrivacyMode.offlineFirst);
      cubit.setAskBeforeSending(ask: false);
      expect(settings.state.privacyMode, PrivacyMode.online);
    });

    test('keep a mode other than the default', () {
      settings.setPrivacyMode(PrivacyMode.offlineOnly);
      web()
        ..next()
        ..next();
      expect(settings.state.privacyMode, PrivacyMode.offlineOnly);
    });

    test('follow the repository by default', () {
      when(() => repository.hasOfflineEngine).thenReturn(false);
      expect(build().state.onDevice, isFalse);
      when(() => repository.hasOfflineEngine).thenReturn(true);
      expect(build().state.onDevice, isTrue);
    });

    test('on a device with an engine, the service step changes nothing', () {
      final cubit = OnboardingCubit(
        repository: repository,
        settings: settings,
        onDevice: true,
      )..goTo(OnboardingStep.service);
      expect(cubit.state.step, OnboardingStep.service);
      expect(settings.state.privacyMode, PrivacyMode.offlineFirst);
    });
  });

  group('navigation', () {
    test('starts on the welcome step', () {
      expect(build().state, const OnboardingState());
    });

    blocTest<OnboardingCubit, OnboardingState>(
      'next walks through every step and stops at the service step',
      build: build,
      act: (cubit) => cubit
        ..next()
        ..next()
        ..next()
        ..next(),
      expect: () => [
        const OnboardingState(step: OnboardingStep.privacy),
        const OnboardingState(step: OnboardingStep.languages),
        const OnboardingState(step: OnboardingStep.service),
      ],
    );

    blocTest<OnboardingCubit, OnboardingState>(
      'back returns and stops at welcome',
      build: build,
      seed: () => const OnboardingState(step: OnboardingStep.privacy),
      act: (cubit) => cubit
        ..back()
        ..back(),
      expect: () => [const OnboardingState()],
    );

    test('setPrivacyMode saves the mode once', () {
      final cubit = build()..setPrivacyMode(PrivacyMode.online);
      expect(settings.state.privacyMode, PrivacyMode.online);
      cubit.setPrivacyMode(PrivacyMode.online);
      expect(settings.state.privacyMode, PrivacyMode.online);
    });

    test('describes failures with the injected wording', () async {
      when(() => repository.pingInstance(any()))
          .thenAnswer((_) async => throw const MozhiApiException('down'));
      final cubit = OnboardingCubit(
        repository: repository,
        settings: settings,
        describeError: (error) => 'policy: $error',
      );
      addTearDown(cubit.close);
      await cubit.addOwnInstance('https://down.example');
      expect(cubit.state.ownInstanceMessage, startsWith('policy: '));
    });

    blocTest<OnboardingCubit, OnboardingState>(
      'goTo jumps and ignores the current step',
      build: build,
      act: (cubit) => cubit
        ..goTo(OnboardingStep.service)
        ..goTo(OnboardingStep.service),
      expect: () => [const OnboardingState(step: OnboardingStep.service)],
    );

    test('finish completes onboarding in the settings', () {
      build().finish();
      expect(settings.state.onboardingComplete, isTrue);
    });
  });

  group('findFastestInstance', () {
    test('pings all instances, sorts them by latency and prefers the '
        'fastest', () async {
      stubLatencies({
        instanceA.url: 300,
        instanceB.url: 100,
        instanceC.url: null,
      });
      final cubit = build();
      final states = <OnboardingState>[];
      final sub = cubit.stream.listen(states.add);

      await cubit.findFastestInstance();
      await sub.cancel();

      expect(states.first.serviceStatus, ServiceStatus.pinging);
      expect(
        states.first.pings.values,
        everyElement(const InstancePing.pending()),
      );
      expect(cubit.state.serviceStatus, ServiceStatus.done);
      expect(cubit.state.pings, {
        instanceA.url: const InstancePing.success(Duration(milliseconds: 300)),
        instanceB.url: const InstancePing.success(Duration(milliseconds: 100)),
        instanceC.url: const InstancePing.failure('down'),
      });
      expect(cubit.state.fastestUrl, instanceB.url);
      expect(cubit.state.selectedUrl, instanceB.url);
      expect(urlsOf(settings), [instanceB.url, instanceA.url, instanceC.url]);
      verify(() => repository.pingInstance(any())).called(3);
    });

    test('pings concurrently and reports results as they arrive', () async {
      final a = Completer<Duration>();
      final b = Completer<Duration>();
      final c = Completer<Duration>();
      stubPing(instanceA.url, () => a.future);
      stubPing(instanceB.url, () => b.future);
      stubPing(instanceC.url, () => c.future);
      final cubit = build();

      final done = cubit.findFastestInstance();
      await Future<void>.delayed(Duration.zero);
      verify(() => repository.pingInstance(any())).called(3);

      b.complete(const Duration(milliseconds: 50));
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.pings[instanceB.url]?.isSuccess, isTrue);
      expect(cubit.state.pings[instanceA.url]?.status, PingStatus.pending);
      expect(cubit.state.serviceStatus, ServiceStatus.pinging);

      // A second request while pinging is ignored.
      await cubit.findFastestInstance();
      verifyNever(() => repository.pingInstance(any()));

      a.complete(const Duration(milliseconds: 10));
      c.complete(const Duration(milliseconds: 30));
      await done;
      expect(urlsOf(settings), [instanceA.url, instanceC.url, instanceB.url]);
    });

    test('marks slow instances as timed out', () async {
      stubLatencies({instanceA.url: 20, instanceB.url: 10});
      stubPing(instanceC.url, () => Completer<Duration>().future);
      final cubit = build(pingTimeout: const Duration(milliseconds: 20));

      await cubit.findFastestInstance();

      expect(cubit.state.pings[instanceC.url], const InstancePing.timedOut());
      expect(urlsOf(settings), [instanceB.url, instanceA.url, instanceC.url]);
    });

    test('only moves the fastest to the front without sort by speed', () async {
      stubLatencies({
        instanceA.url: 300,
        instanceB.url: 200,
        instanceC.url: 100,
      });
      final cubit = build()..setSortBySpeed(enabled: false);

      await cubit.findFastestInstance();

      expect(cubit.state.sortBySpeed, isFalse);
      expect(urlsOf(settings), [instanceC.url, instanceA.url, instanceB.url]);
    });

    test(
      'toggling sort by speed reorders or restores the original order',
      () async {
        stubLatencies({
          instanceA.url: 300,
          instanceB.url: 200,
          instanceC.url: 100,
        });
        final cubit = build();
        await cubit.findFastestInstance();
        expect(urlsOf(settings), [instanceC.url, instanceB.url, instanceA.url]);

        cubit.setSortBySpeed(enabled: false);
        expect(urlsOf(settings), [instanceC.url, instanceA.url, instanceB.url]);

        cubit.setSortBySpeed(enabled: true);
        expect(urlsOf(settings), [instanceC.url, instanceB.url, instanceA.url]);

        final before = cubit.state;
        cubit.setSortBySpeed(enabled: true);
        expect(cubit.state, same(before));
      },
    );

    test('toggling before pinging only changes the flag', () {
      final cubit = build()..setSortBySpeed(enabled: false);
      expect(cubit.state.sortBySpeed, isFalse);
      expect(urlsOf(settings), [for (final i in testInstances) i.url]);
    });

    test('the instance picked by the user wins over the fastest', () async {
      final a = Completer<Duration>();
      stubPing(instanceA.url, () => a.future);
      stubLatencies({instanceB.url: 100, instanceC.url: 200});
      final cubit = build();

      final done = cubit.findFastestInstance();
      cubit.selectInstance(instanceC.url);
      expect(urlsOf(settings).first, instanceC.url);
      a.complete(const Duration(milliseconds: 50));
      await done;

      expect(cubit.state.selectedUrl, instanceC.url);
      expect(cubit.state.fastestUrl, instanceA.url);
      expect(urlsOf(settings), [instanceC.url, instanceA.url, instanceB.url]);
    });

    test('tests with a translation of Google by default', () async {
      stubLatencies({instanceA.url: 30, instanceB.url: 20, instanceC.url: 10});
      final cubit = build();
      expect(OnboardingCubit.pingEngineOf(settings.state.engineId), 'google');

      await cubit.findFastestInstance();

      final engines = verify(
        () =>
            repository.pingInstance(any(), engine: captureAny(named: 'engine')),
      ).captured;
      expect(engines, ['google', 'google', 'google']);
    });

    test('tests with the chosen Mozhi engine', () async {
      stubLatencies({instanceA.url: 30, instanceB.url: 20, instanceC.url: 10});
      settings.setEngine('mozhi:deepl');
      final cubit = build();
      expect(OnboardingCubit.pingEngineOf(settings.state.engineId), 'deepl');

      await cubit.findFastestInstance();

      verify(() => repository.pingInstance(any(), engine: 'deepl')).called(3);
    });

    test('pingEngineOf tests Google unless a Mozhi engine is chosen', () {
      expect(OnboardingCubit.pingEngineOf(null), 'google');
      expect(OnboardingCubit.pingEngineOf('mozhi:yandex'), 'yandex');
      expect(OnboardingCubit.pingEngineOf('ai:claude'), 'google');
      expect(
        OnboardingCubit.pingEngineOf('mozhi:'),
        OnboardingCubit.defaultPingEngine,
      );
    });

    test('a server that answers but does not translate is not the '
        'fastest', () async {
      stubNoTranslation(instanceA.url);
      stubLatencies({instanceB.url: 300, instanceC.url: null});
      final cubit = build();

      await cubit.findFastestInstance();

      expect(
        cubit.state.pings[instanceA.url],
        const InstancePing.noTranslation('Post: 429'),
      );
      expect(cubit.state.pings[instanceA.url]?.isSuccess, isFalse);
      expect(cubit.state.fastestUrl, instanceB.url);
      expect(cubit.state.noneReachable, isFalse);
      expect(urlsOf(settings), [instanceB.url, instanceA.url, instanceC.url]);
    });

    test('says when servers answered but none translated', () async {
      stubNoTranslation(instanceA.url);
      stubNoTranslation(instanceB.url);
      stubLatencies({instanceC.url: null});
      final cubit = build();

      await cubit.findFastestInstance();

      expect(cubit.state.noneReachable, isTrue);
      expect(cubit.state.noneTranslates, isTrue);
      expect(cubit.state.selectedUrl, isNull);
      expect(urlsOf(settings), [for (final i in testInstances) i.url]);
    });

    test('keeps the order when no instance answers', () async {
      stubLatencies({
        instanceA.url: null,
        instanceB.url: null,
        instanceC.url: null,
      });
      final cubit = build();

      await cubit.findFastestInstance();

      expect(cubit.state.noneReachable, isTrue);
      expect(cubit.state.noneTranslates, isFalse);
      expect(cubit.state.selectedUrl, isNull);
      expect(urlsOf(settings), [for (final i in testInstances) i.url]);
    });

    test('finishes immediately without instances', () async {
      await settings.close();
      settings = createSettings(const AppSettings(instances: []));
      final cubit = build();

      await cubit.findFastestInstance();

      expect(cubit.state.serviceStatus, ServiceStatus.done);
      expect(cubit.state.pings, isEmpty);
      expect(cubit.state.noneReachable, isFalse);
      verifyNever(() => repository.pingInstance(any()));
    });

    test('ignores results after close', () async {
      final a = Completer<Duration>();
      stubPing(instanceA.url, () => a.future);
      stubLatencies({instanceB.url: 10, instanceC.url: 20});
      final cubit = build();

      final done = cubit.findFastestInstance();
      await Future<void>.delayed(Duration.zero);
      await cubit.close();
      a.complete(const Duration(milliseconds: 1));
      await done;

      expect(urlsOf(settings), [for (final i in testInstances) i.url]);
    });
  });

  group('normalizeOwnInstanceUrl', () {
    test('normalizes valid input and rejects invalid input', () {
      expect(
        normalizeOwnInstanceUrl('mozhi.example.com/api/'),
        Uri.parse('https://mozhi.example.com'),
      );
      expect(normalizeOwnInstanceUrl('not a url'), isNull);
    });
  });

  group('addOwnInstance', () {
    test('rejects empty input', () async {
      final cubit = build();
      await cubit.addOwnInstance('   ');
      expect(cubit.state.ownInstanceStatus, OwnInstanceStatus.failure);
      expect(cubit.state.ownInstanceError, OwnInstanceError.empty);
      verifyNever(() => repository.pingInstance(any()));
    });

    test('rejects invalid urls', () async {
      final cubit = build();
      for (final input in ['ftp://mozhi.example', 'not a url', 'a:99999']) {
        await cubit.addOwnInstance(input);
        expect(
          cubit.state.ownInstanceError,
          OwnInstanceError.invalidUrl,
          reason: input,
        );
      }
      verifyNever(() => repository.pingInstance(any()));
    });

    test('tests, adds and prefers a reachable instance', () async {
      const url = 'https://mozhi.example.com';
      stubLatencies({url: 120});
      final cubit = build();
      final states = <OnboardingState>[];
      final sub = cubit.stream.listen(states.add);

      await cubit.addOwnInstance(' mozhi.example.com/api/ ');
      await sub.cancel();

      expect(states.first.ownInstanceStatus, OwnInstanceStatus.testing);
      expect(cubit.state.ownInstanceStatus, OwnInstanceStatus.success);
      expect(cubit.state.ownInstanceLatency, const Duration(milliseconds: 120));
      expect(cubit.state.selectedUrl, url);
      expect(
        cubit.state.pings[url],
        const InstancePing.success(Duration(milliseconds: 120)),
      );
      expect(urlsOf(settings), [url, ...testInstances.map((i) => i.url)]);
      expect(settings.state.instances.first.isCustom, isTrue);
    });

    test('refuses plain http to a remote host', () async {
      stubLatencies({'http://mozhi.example.com': 50});
      final cubit = build();

      await cubit.addOwnInstance('http://mozhi.example.com');

      expect(cubit.state.ownInstanceStatus, OwnInstanceStatus.failure);
      expect(cubit.state.ownInstanceError, OwnInstanceError.insecure);
      verifyNever(() => repository.pingInstance(any()));
      expect(urlsOf(settings), [for (final i in testInstances) i.url]);
    });

    test('adds plain http on the local network without confirmation', () async {
      const url = 'http://192.168.1.20:3000';
      stubLatencies({url: 5});
      final cubit = build();

      await cubit.addOwnInstance(url);

      expect(cubit.state.ownInstanceStatus, OwnInstanceStatus.success);
      expect(urlsOf(settings).first, url);
    });

    test('does not duplicate an existing instance', () async {
      stubLatencies({instanceC.url: 80});
      final cubit = build();

      await cubit.addOwnInstance('https://c.example/');

      expect(cubit.state.ownInstanceStatus, OwnInstanceStatus.success);
      expect(urlsOf(settings), [instanceC.url, instanceA.url, instanceB.url]);
      expect(settings.state.instances.first.label, 'Charlie');
    });

    test('reports unreachable instances', () async {
      const url = 'https://down.example';
      stubLatencies({url: null});
      final cubit = build();

      await cubit.addOwnInstance(url);

      expect(cubit.state.ownInstanceStatus, OwnInstanceStatus.failure);
      expect(cubit.state.ownInstanceError, OwnInstanceError.unreachable);
      expect(cubit.state.ownInstanceMessage, 'down');
      expect(urlsOf(settings), [for (final i in testInstances) i.url]);
    });

    test('tests the own instance with the engine the app uses', () async {
      const url = 'https://mozhi.example.com';
      stubLatencies({url: 40});
      settings.setEngine('mozhi:yandex');
      final cubit = build();

      await cubit.addOwnInstance(url);

      expect(cubit.state.ownInstanceStatus, OwnInstanceStatus.success);
      verify(
        () => repository.pingInstance(
          any(that: isA<MozhiInstance>().having((i) => i.url, 'url', url)),
          engine: 'yandex',
        ),
      ).called(1);
    });

    test('refuses an instance whose engine does not translate', () async {
      const url = 'https://broken.example';
      stubNoTranslation(url, message: 'Post "https://x": 429');
      final cubit = build();

      await cubit.addOwnInstance(url);

      expect(cubit.state.ownInstanceStatus, OwnInstanceStatus.failure);
      expect(cubit.state.ownInstanceError, OwnInstanceError.noTranslation);
      expect(cubit.state.ownInstanceMessage, 'Post "https://x": 429');
      expect(urlsOf(settings), [for (final i in testInstances) i.url]);
    });

    test('adds an instance that only lacks the engine', () async {
      const url = 'https://libre-only.example';
      stubNoTranslation(
        url,
        message: 'Engine does not exist or has been disabled',
      );
      final cubit = build();

      await cubit.addOwnInstance(url);

      expect(cubit.state.ownInstanceStatus, OwnInstanceStatus.success);
      expect(cubit.state.ownInstanceLatency, isNotNull);
      expect(cubit.state.pings[url]?.isSuccess, isTrue);
      expect(urlsOf(settings).first, url);
    });

    test('reports timeouts', () async {
      const url = 'https://slow.example';
      stubPing(url, () => Completer<Duration>().future);
      final cubit = build(pingTimeout: const Duration(milliseconds: 10));

      await cubit.addOwnInstance(url);

      expect(cubit.state.ownInstanceError, OwnInstanceError.timedOut);
    });

    test(
      'ownInstanceChanged resets the result and drops pending tests',
      () async {
        const url = 'https://late.example';
        final ping = Completer<Duration>();
        stubPing(url, () => ping.future);
        final cubit = build();
        final before = cubit.state;
        cubit.ownInstanceChanged();
        expect(cubit.state, same(before));

        final done = cubit.addOwnInstance(url);
        expect(cubit.state.ownInstanceStatus, OwnInstanceStatus.testing);
        cubit.ownInstanceChanged();
        expect(cubit.state.ownInstanceStatus, OwnInstanceStatus.idle);
        ping.complete(const Duration(milliseconds: 5));
        await done;

        expect(cubit.state.ownInstanceStatus, OwnInstanceStatus.idle);
        expect(urlsOf(settings), isNot(contains(url)));
      },
    );

    test('drops stale failures and timeouts', () async {
      const failing = 'https://failing.example';
      const slow = 'https://slow.example';
      final failure = Completer<Duration>();
      stubPing(failing, () => failure.future);
      stubPing(slow, () => Completer<Duration>().future);
      final cubit = build(pingTimeout: const Duration(milliseconds: 10));

      final first = cubit.addOwnInstance(failing);
      cubit.ownInstanceChanged();
      failure.completeError(const MozhiApiException('x'));
      await first;
      expect(cubit.state.ownInstanceStatus, OwnInstanceStatus.idle);

      final second = cubit.addOwnInstance(slow);
      cubit.ownInstanceChanged();
      await second;
      expect(cubit.state.ownInstanceStatus, OwnInstanceStatus.idle);
    });
  });

  group('languages', () {
    const french = Language(code: 'fr', name: 'French');

    test('sets the source and target in the settings', () {
      build()
        ..setSourceLanguage(french)
        ..setTargetLanguage(const Language(code: 'de', name: 'German'));
      expect(settings.state.source, french);
      expect(settings.state.target.code, 'de');
    });

    test('detect language is a valid source but not a target', () {
      settings.setLanguages(source: french);
      build()
        ..setSourceLanguage(Language.auto)
        ..setTargetLanguage(Language.auto);
      expect(settings.state.source, Language.auto);
      expect(settings.state.target.code, 'en');
    });

    test('remembers the last source picked, not Detect language', () {
      const german = Language(code: 'de', name: 'German');
      final cubit = build();
      expect(cubit.state.pickedSource, isNull);
      cubit.setSourceLanguage(french);
      expect(cubit.state.pickedSource, french);
      cubit.setSourceLanguage(Language.auto);
      expect(cubit.state.pickedSource, french);
      cubit.setSourceLanguage(german);
      expect(cubit.state.pickedSource, german);
      expect(
        cubit.state.copyWith(step: OnboardingStep.service).pickedSource,
        german,
      );
    });

    test('ignores custom and unchanged languages', () {
      final calls = <(Language?, Language?)>[];
      final cubit = OnboardingCubit(
        repository: repository,
        settings: settings,
        setLanguages: ({source, target}) => calls.add((source, target)),
      );
      addTearDown(cubit.close);
      const pirate = Language(code: 'Pirate', name: 'Pirate', isCustom: true);
      cubit
        ..setSourceLanguage(pirate)
        ..setTargetLanguage(pirate)
        ..setSourceLanguage(settings.state.source)
        ..setTargetLanguage(settings.state.target);
      expect(calls, isEmpty);

      cubit
        ..setSourceLanguage(french)
        ..setTargetLanguage(french);
      expect(calls, [(french, null), (null, french)]);
    });
  });

  group('languages step', () {
    test("knows the phone's languages and whether to check downloads", () {
      final cubit = OnboardingCubit(
        repository: repository,
        settings: settings,
        onDevice: true,
        deviceLanguages: () => ['fr-FR', 'de'],
        preselectDownloads: true,
      );
      addTearDown(cubit.close);
      expect(cubit.state.deviceLanguages, ['fr-FR', 'de']);
      expect(cubit.state.preselectDownloads, isTrue);
      // By default: the platform's locales; checked off Android only.
      final platform = OnboardingCubit(
        repository: repository,
        settings: settings,
        onDevice: true,
      );
      addTearDown(platform.close);
      expect(platform.state.deviceLanguages, isNotEmpty);
      expect(platform.state.preselectDownloads, isFalse);
    });

    blocTest<OnboardingCubit, OnboardingState>(
      'loadFreeSpace reads the room for downloads',
      build: () => OnboardingCubit(
        repository: repository,
        settings: settings,
        onDevice: true,
        deviceLanguages: () => const [],
        preselectDownloads: true,
        freeSpace: () async => 123,
      ),
      act: (cubit) => cubit.loadFreeSpace(),
      expect: () => [
        const OnboardingState(preselectDownloads: true, freeBytes: 123),
      ],
    );

    for (final (name, answer) in [
      ('unknown', () async => null),
      ('failing', () => Future<int?>.error(StateError('no channel'))),
    ]) {
      blocTest<OnboardingCubit, OnboardingState>(
        'loadFreeSpace keeps $name room unknown',
        build: () => OnboardingCubit(
          repository: repository,
          settings: settings,
          onDevice: true,
          deviceLanguages: () => const [],
          preselectDownloads: true,
          freeSpace: answer,
        ),
        act: (cubit) => cubit.loadFreeSpace(),
        expect: () => const <OnboardingState>[],
      );
    }

    test('loadFreeSpace asks nothing when downloads are not checked', () async {
      var asked = false;
      final cubit = OnboardingCubit(
        repository: repository,
        settings: settings,
        onDevice: true,
        preselectDownloads: false,
        freeSpace: () async {
          asked = true;
          return 1;
        },
      );
      addTearDown(cubit.close);
      await cubit.loadFreeSpace();
      expect(asked, isFalse);
      expect(cubit.state.freeBytes, isNull);
    });

    test('loadFreeSpace after close emits nothing', () async {
      final room = Completer<int?>();
      final cubit = OnboardingCubit(
        repository: repository,
        settings: settings,
        onDevice: true,
        preselectDownloads: true,
        freeSpace: () => room.future,
      );
      final loading = cubit.loadFreeSpace();
      await cubit.close();
      room.complete(5);
      await loading;
      expect(cubit.state.freeBytes, isNull);
    });

    blocTest<OnboardingCubit, OnboardingState>(
      'chooseDownload remembers each answer once',
      build: build,
      act: (cubit) => cubit
        ..chooseDownload('fr', download: true)
        ..chooseDownload('fr', download: true)
        ..chooseDownload('de', download: false)
        ..chooseDownload('fr', download: false),
      expect: () => [
        const OnboardingState(downloadChoices: {'fr': true}),
        const OnboardingState(downloadChoices: {'fr': true, 'de': false}),
        const OnboardingState(downloadChoices: {'fr': false, 'de': false}),
      ],
    );
  });
}
