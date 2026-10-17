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
}
