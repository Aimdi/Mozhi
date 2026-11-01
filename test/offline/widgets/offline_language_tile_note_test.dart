import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/offline/offline.dart';

import '../../helpers/helpers.dart';

void main() {
  const spanish = OfflineLanguage(code: 'es', name: 'Spanish');

  late List<String> taps;

  setUp(() => taps = []);

  Future<void> pump(
    WidgetTester tester, {
    bool downloaded = false,
    bool outdated = false,
    bool canDownload = true,
    String? note,
    int? downloadSize = 11400000,
  }) => tester.pumpApp(
    Scaffold(
      body: OfflineLanguageTile(
        language: spanish,
        downloaded: downloaded,
        outdated: outdated,
        downloadSize: downloadSize,
        canDownload: canDownload,
        note: note,
        onDownload: () => taps.add('download'),
        onDelete: () => taps.add('delete'),
      ),
    ),
  );

  VoidCallback? onPressed(WidgetTester tester, String key) => tester
      .widget<ButtonStyleButton>(
        find.descendant(
          of: find.byKey(Key(key)),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
          matchRoot: true,
        ),
      )
      .onPressed;

  testWidgets('a note is a second line under the size', (tester) async {
    await pump(tester, note: 'Definitions in English');
    expect(find.text('Definitions in English'), findsOneWidget);
    expect(find.textContaining('download'), findsOneWidget);
  });

  testWidgets('a note alone is the subtitle', (tester) async {
    await pump(tester, note: 'Definitions in English', downloadSize: null);
    final tile = tester.widget<ListTile>(find.byType(ListTile));
    expect(tile.subtitle, isA<Column>());
    expect(find.text('Definitions in English'), findsOneWidget);
  });

  testWidgets('without downloads, Download is disabled', (tester) async {
    await pump(tester, canDownload: false);
    expect(onPressed(tester, 'offline_download_pill'), isNull);
    await tester.tap(find.text('Download'), warnIfMissed: false);
    expect(taps, isEmpty);
  });

  testWidgets('without downloads, Update is disabled; Delete works', (
    tester,
  ) async {
    await pump(tester, downloaded: true, outdated: true, canDownload: false);
    expect(onPressed(tester, 'offline_update_pill'), isNull);
    await tester.tap(find.byIcon(Icons.delete_outline));
    expect(taps, ['delete']);
  });
}
