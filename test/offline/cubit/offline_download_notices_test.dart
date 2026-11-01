import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/offline/offline.dart';

void main() {
  const outcome = OfflineModelOutcome(
    language: OfflineLanguage(code: 'fr', name: 'French'),
    operation: OfflineModelOperation.download,
    succeeded: false,
  );

  late OfflineDownloadNotices notices;
  late List<OfflineModelOutcome> told;

  setUp(() {
    notices = OfflineDownloadNotices();
    told = [];
    notices.failures.listen(told.add);
  });

  tearDown(() => notices.close());

  group(OfflineDownloadNotices, () {
    test('has an app-wide instance', () {
      expect(
        OfflineDownloadNotices.instance,
        same(OfflineDownloadNotices.instance),
      );
    });

    test('tells a failure nobody saw', () async {
      notices.join('fr')
        ..leave()
        ..failedUnseen(outcome)
        ..end();
      await pumpEventQueue();
      expect(told, [outcome]);
    });

    test('says nothing while another screen is open', () async {
      final closed = notices.join('fr');
      final open = notices.join('fr');
      closed
        ..leave()
        ..failedUnseen(outcome)
        ..end();
      open
        ..shown()
        ..end();
      await pumpEventQueue();
      expect(told, isEmpty);
    });

    test('says nothing once another screen has shown it', () async {
      final closed = notices.join('fr')..leave();
      notices.join('fr')
        ..shown()
        ..end();
      closed
        ..failedUnseen(outcome)
        ..end();
      await pumpEventQueue();
      expect(told, isEmpty);
    });

    test('tells it once when every screen has closed', () async {
      final one = notices.join('fr')..leave();
      final two = notices.join('fr')..leave();
      one.failedUnseen(outcome);
      two.failedUnseen(outcome);
      one.end();
      two
        ..end()
        ..end();
      await pumpEventQueue();
      expect(told, [outcome]);
    });

    test('a later download of the language starts afresh', () async {
      notices.join('fr')
        ..shown()
        ..end();
      notices.join('fr')
        ..leave()
        ..failedUnseen(outcome);
      await pumpEventQueue();
      expect(told, [outcome]);
    });

    test('languages are apart', () async {
      notices.join('de').shown();
      notices.join('fr').failedUnseen(outcome);
      await pumpEventQueue();
      expect(told, [outcome]);
    });
  });
}
