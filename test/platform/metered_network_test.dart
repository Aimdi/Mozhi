import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/platform/metered_network.dart';
import 'package:mozhi/platform/privacy_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group(MeteredNetwork, () {
    final channel = privacyChannel();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late List<MethodCall> calls;

    void answer(Object? Function() reply) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return reply();
      });
    }

    setUp(() => calls = []);
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    for (final metered in [true, false]) {
      test('reports what Android answers ($metered)', () async {
        answer(() => metered);

        expect(await MeteredNetwork(isAndroid: true).isMetered(), metered);
        expect(calls.single.method, 'isActiveNetworkMetered');
      });
    }

    test('counts an empty answer as metered', () async {
      answer(() => null);

      expect(await MeteredNetwork(isAndroid: true).isMetered(), isTrue);
    });

    test('counts platform errors as metered', () async {
      answer(() => throw PlatformException(code: 'denied'));

      expect(await MeteredNetwork(isAndroid: true).isMetered(), isTrue);
    });

    test('counts a missing platform side as metered', () async {
      expect(await MeteredNetwork(isAndroid: true).isMetered(), isTrue);
    });

    test('reports unmetered without asking off Android', () async {
      answer(() => true);

      // Tests run on a desktop host: the default is not Android.
      expect(await MeteredNetwork().isMetered(), isFalse);
      expect(await MeteredNetwork.instance.isMetered(), isFalse);
      expect(calls, isEmpty);
    });
  });

  group('MeteredNetwork.networkAccess', () {
    final channel = privacyChannel();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    void answer(Object? Function() reply) =>
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'networkAccess');
          return reply();
        });

    test('reports what Android answers', () async {
      answer(
        () => {
          'internetPermission': false,
          'hasNetwork': true,
          'blocked': false,
        },
      );
      final access = await MeteredNetwork(isAndroid: true).networkAccess();
      expect(
        access,
        const NetworkAccess(
          internetPermission: false,
          hasNetwork: true,
          blocked: false,
        ),
      );
      expect(access!.denied, isTrue);
      expect(access.usable, isFalse);
    });

    test('a blocked network is denied, a missing one is not usable', () {
      const blocked = NetworkAccess(
        internetPermission: true,
        hasNetwork: true,
        blocked: true,
      );
      const none = NetworkAccess(
        internetPermission: true,
        hasNetwork: false,
        blocked: false,
      );
      const fine = NetworkAccess(
        internetPermission: true,
        hasNetwork: true,
        blocked: false,
      );
      expect((blocked.denied, blocked.usable), (true, false));
      expect((none.denied, none.usable), (false, false));
      expect((fine.denied, fine.usable), (false, true));
    });

    test('missing keys count as access', () async {
      answer(() => <String, Object?>{});
      final access = await MeteredNetwork(isAndroid: true).networkAccess();
      expect(access?.usable, isTrue);
    });

    test(
      'is unknown on errors, without a platform side and off Android',
      () async {
        answer(() => throw PlatformException(code: 'denied'));
        expect(await MeteredNetwork(isAndroid: true).networkAccess(), isNull);
        answer(() => null);
        expect(await MeteredNetwork(isAndroid: true).networkAccess(), isNull);
        messenger.setMockMethodCallHandler(channel, null);
        expect(await MeteredNetwork(isAndroid: true).networkAccess(), isNull);
        expect(await MeteredNetwork().networkAccess(), isNull);
      },
    );
  });
}
