import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/app_lock/data/app_lock_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const texts = AppLockPromptTexts(
    title: 'Unlock Mozhi',
    subtitle: 'Use your fingerprint',
    fallback: 'Use PIN',
  );

  group(AppLockPromptResult, () {
    test('reads every result by name and anything else as error', () {
      for (final result in AppLockPromptResult.values) {
        expect(AppLockPromptResult.fromName(result.name), result);
      }
      expect(AppLockPromptResult.fromName('maybe'), AppLockPromptResult.error);
      expect(AppLockPromptResult.fromName(null), AppLockPromptResult.error);
    });
  });

  group(AppLockPromptTexts, () {
    test('are the arguments of authenticate', () {
      expect(texts.toMap(), {
        'title': 'Unlock Mozhi',
        'subtitle': 'Use your fingerprint',
        'fallback': 'Use PIN',
      });
    });

    test('support value equality', () {
      expect(
        texts,
        const AppLockPromptTexts(
          title: 'Unlock Mozhi',
          subtitle: 'Use your fingerprint',
          fallback: 'Use PIN',
        ),
      );
    });
  });

  group(AppLockSession, () {
    test('parses the platform answer', () {
      expect(
        AppLockSession.fromMap(const {
          'secure': true,
          'unlocked': true,
          'awayMs': 1500,
          'ownTripMs': 60000,
          'currentMs': 200,
          'currentIsOwnTrip': true,
          'inFront': false,
        }),
        const AppLockSession(
          secure: true,
          unlocked: true,
          longestAway: Duration(milliseconds: 1500),
          longestOwnTrip: Duration(minutes: 1),
          currentAway: Duration(milliseconds: 200),
          currentIsOwnTrip: true,
          inFront: false,
        ),
      );
    });

    test('reads -1 as no absence', () {
      final session = AppLockSession.fromMap(const {
        'secure': true,
        'awayMs': -1,
        'ownTripMs': -1,
        'currentMs': -1,
      });

      expect(session.longestAway, isNull);
      expect(session.longestOwnTrip, isNull);
      expect(session.currentAway, isNull);
    });

    test('falls back to the safe values', () {
      expect(AppLockSession.fromMap(null), AppLockSession.unavailable);
      final session = AppLockSession.fromMap(const {
        'secure': 'yes',
        'unlocked': 1,
        'awayMs': '5',
      });
      expect(session.secure, isFalse);
      expect(session.unlocked, isFalse);
      expect(session.longestAway, isNull);
      expect(session.inFront, isTrue);
    });

    test('unavailable is not secure', () {
      expect(AppLockSession.unavailable.secure, isFalse);
    });
  });

  group(UnavailableAppLockPlatform, () {
    const platform = UnavailableAppLockPlatform();

    test('has nothing to unlock with', () async {
      expect(await platform.session(), AppLockSession.unavailable);
      expect(
        await platform.authenticate(texts),
        AppLockPromptResult.unavailable,
      );
      await expectLater(platform.setUnlocked(unlocked: true), completes);
      await expectLater(platform.setProtected(enabled: true), completes);
    });
  });

  group(MethodChannelAppLockPlatform, () {
    const channel = MethodChannel(MethodChannelAppLockPlatform.channelName);
    late List<MethodCall> calls;
    late Object? Function(MethodCall call) answer;
    final platform = MethodChannelAppLockPlatform();

    setUp(() {
      calls = [];
      answer = (_) => null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return answer(call);
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('uses the app lock channel', () {
      expect(
        MethodChannelAppLockPlatform.channelName,
        'io.github.aimdi.mozhi/app_lock',
      );
    });

    test('reads the session', () async {
      answer = (_) => {'secure': true, 'unlocked': true, 'awayMs': 10};

      final session = await platform.session();

      expect(calls.single.method, 'session');
      expect(session.secure, isTrue);
      expect(session.unlocked, isTrue);
      expect(session.longestAway, const Duration(milliseconds: 10));
    });

    test('records whether the app is unlocked', () async {
      await platform.setUnlocked(unlocked: true);

      expect(calls.single.method, 'setUnlocked');
      expect(calls.single.arguments, isTrue);
    });

    test('asks for protection from Recents', () async {
      await platform.setProtected(enabled: false);

      expect(calls.single.method, 'setProtected');
      expect(calls.single.arguments, isFalse);
    });

    test('authenticates with the texts', () async {
      answer = (_) => 'cancelled';

      expect(await platform.authenticate(texts), AppLockPromptResult.cancelled);
      expect(calls.single.method, 'authenticate');
      expect(calls.single.arguments, texts.toMap());
    });

    test('throws what the platform throws', () async {
      answer = (_) => throw PlatformException(code: 'boom');

      await expectLater(platform.session(), throwsA(isA<PlatformException>()));
      await expectLater(
        platform.setUnlocked(unlocked: false),
        throwsA(isA<PlatformException>()),
      );
    });

    group('without a platform side', () {
      setUp(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      test('is unavailable', () async {
        expect(await platform.session(), AppLockSession.unavailable);
        expect(
          await platform.authenticate(texts),
          AppLockPromptResult.unavailable,
        );
        await expectLater(platform.setUnlocked(unlocked: true), completes);
        await expectLater(platform.setProtected(enabled: true), completes);
      });
    });
  });

  group('createAppLockPlatform', () {
    test('is the channel on Android', () {
      expect(
        createAppLockPlatform(isAndroid: true),
        isA<MethodChannelAppLockPlatform>(),
      );
    });

    test('is unavailable elsewhere', () {
      expect(
        createAppLockPlatform(isAndroid: false),
        isA<UnavailableAppLockPlatform>(),
      );
      // Tests run on a desktop host.
      expect(createAppLockPlatform(), isA<UnavailableAppLockPlatform>());
    });
  });
}
