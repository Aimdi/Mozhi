import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/presets/widgets/presets_share.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PresetsShare', () {
    const channel = MethodChannel('dev.fluttercommunity.plus/share');
    late List<MethodCall> calls;

    setUp(() {
      calls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return 'dev.fluttercommunity.plus/share/unavailable';
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      PresetsShare.reset();
    });

    test('shares a file, or falls back to plain text', () async {
      await PresetsShare.share(
        'a,b',
        fileName: 'terms.csv',
        mimeType: 'text/csv',
      );
      expect(calls, isNotEmpty);
      final arguments = calls.last.arguments as Map<Object?, Object?>;
      // Without a temporary directory (tests) the file cannot be written and
      // the text is shared instead.
      expect(arguments['text'] == 'a,b' || arguments['paths'] != null, isTrue);
    });

    test('reset restores the default implementation', () async {
      var stubbed = 0;
      PresetsShare.share =
          (text, {required fileName, required mimeType}) async {
            stubbed++;
          };
      PresetsShare.reset();
      await PresetsShare.share('x', fileName: 'x.json', mimeType: 'a/b');
      expect(stubbed, 0);
      expect(calls, isNotEmpty);
    });
  });
}
