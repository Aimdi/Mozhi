import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/offline/offline.dart';

import '../../helpers/helpers.dart';

void main() {
  const german = OfflineLanguage(
    code: 'de',
    name: 'German',
    nativeName: 'Deutsch',
  );

  group('OfflineLanguageTile', () {
    late List<String> taps;

    setUp(() => taps = []);

    Future<void> pump(
      WidgetTester tester, {
      bool downloaded = false,
      OfflineModelOperation? pending,
      bool wifiOnly = true,
      bool enabled = true,
      OfflineLanguage language = german,
    }) => tester.pumpApp(
      Scaffold(
        body: OfflineLanguageTile(
          language: language,
          downloaded: downloaded,
          pending: pending,
          wifiOnly: wifiOnly,
          enabled: enabled,
          onDownload: () => taps.add('download'),
          onDelete: () => taps.add('delete'),
        ),
      ),
    );

    testWidgets('offers a download for missing models', (tester) async {
      await pump(tester);
      expect(find.text('German'), findsOneWidget);
      expect(find.text('Deutsch'), findsOneWidget);
      expect(find.text('Downloaded'), findsNothing);
      await tester.tap(find.byTooltip('Download German'));
      expect(taps, ['download']);
    });

    testWidgets('shows a badge and a delete action when downloaded', (
      tester,
    ) async {
      await pump(tester, downloaded: true);
      expect(find.text('Downloaded'), findsOneWidget);
      expect(find.byIcon(Icons.offline_pin), findsOneWidget);
      await tester.tap(find.byTooltip('Delete German'));
      expect(taps, ['delete']);
    });

    testWidgets('shows progress while downloading', (tester) async {
      await pump(tester, pending: OfflineModelOperation.download);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Downloading when on Wi-Fi…'), findsOneWidget);
      expect(find.byType(IconButton), findsNothing);

      await pump(
        tester,
        pending: OfflineModelOperation.download,
        wifiOnly: false,
      );
      expect(find.text('Downloading…'), findsOneWidget);
    });

    testWidgets('shows progress while deleting', (tester) async {
      await pump(
        tester,
        downloaded: true,
        pending: OfflineModelOperation.delete,
      );
      expect(find.text('Deleting…'), findsOneWidget);
      expect(find.bySemanticsLabel('Deleting…'), findsOneWidget);
    });

    testWidgets('disables the actions when not enabled', (tester) async {
      await pump(tester, enabled: false);
      await tester.tap(find.byTooltip('Download German'));
      await pump(tester, enabled: false, downloaded: true);
      await tester.tap(find.byTooltip('Delete German'));
      expect(taps, isEmpty);
    });

    testWidgets('omits the subtitle without a native name', (tester) async {
      await pump(
        tester,
        language: const OfflineLanguage(code: 'xx', name: 'xx'),
      );
      final tile = tester.widget<ListTile>(find.byType(ListTile));
      expect(tile.subtitle, isNull);
    });
  });

  group('confirmDeleteOfflineLanguage', () {
    Future<List<bool>> open(WidgetTester tester) async {
      final results = <bool>[];
      await tester.pumpApp(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async => results.add(
              await confirmDeleteOfflineLanguage(context, german),
            ),
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return results;
    }

    testWidgets('returns true when confirmed', (tester) async {
      final results = await open(tester);
      expect(find.text('Delete German?'), findsOneWidget);
      expect(
        find.text(
          'Offline translation from and to German stops working until you '
          'download it again.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(results, [true]);
    });

    testWidgets('returns false when cancelled', (tester) async {
      final results = await open(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(results, [false]);
    });

    testWidgets('returns false when dismissed', (tester) async {
      final results = await open(tester);
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(results, [false]);
    });
  });
}
