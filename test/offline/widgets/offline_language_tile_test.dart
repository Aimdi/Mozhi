import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
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
      double? progress,
      int? downloadSize,
      int? installedSize,
      bool outdated = false,
      bool builtIn = false,
      bool enabled = true,
      OfflineLanguage language = german,
    }) => tester.pumpApp(
      Scaffold(
        body: OfflineLanguageTile(
          language: language,
          downloaded: downloaded,
          pending: pending,
          progress: progress,
          downloadSize: downloadSize,
          installedSize: installedSize,
          outdated: outdated,
          builtIn: builtIn,
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

    testWidgets('uses an inverse pill to download', (tester) async {
      await pump(tester);
      expect(find.widgetWithText(FilledButton, 'Download'), findsOneWidget);
      expect(find.byType(LanguageAvatar), findsOneWidget);
    });

    testWidgets('the downloaded pill reads Delete while hovered', (
      tester,
    ) async {
      await pump(tester, downloaded: true);
      expect(find.widgetWithText(OutlinedButton, 'Downloaded'), findsOneWidget);
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(gesture.removePointer);
      await gesture.addPointer(location: Offset.zero);
      await gesture.moveTo(
        tester.getCenter(find.byKey(const Key('offline_downloaded_pill'))),
      );
      await tester.pumpAndSettle();
      expect(find.widgetWithText(OutlinedButton, 'Delete'), findsOneWidget);
      await gesture.moveTo(Offset.zero);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(OutlinedButton, 'Downloaded'), findsOneWidget);
    });

    testWidgets('shows progress while downloading', (tester) async {
      await pump(tester, pending: OfflineModelOperation.download);
      final spinner = find.byType(CircularProgressIndicator);
      expect(spinner, findsOneWidget);
      expect(tester.widget<CircularProgressIndicator>(spinner).value, isNull);
      expect(find.text('Downloading…'), findsOneWidget);
      expect(find.byType(IconButton), findsNothing);

      await pump(
        tester,
        pending: OfflineModelOperation.download,
        progress: 0.426,
      );
      expect(find.text('Downloading… 42%'), findsOneWidget);
      expect(tester.widget<CircularProgressIndicator>(spinner).value, 0.426);
    });

    testWidgets('shows progress while updating', (tester) async {
      await pump(
        tester,
        downloaded: true,
        outdated: true,
        pending: OfflineModelOperation.update,
      );
      expect(find.text('Updating…'), findsOneWidget);

      await pump(
        tester,
        downloaded: true,
        outdated: true,
        pending: OfflineModelOperation.update,
        progress: 1,
      );
      expect(find.text('Updating… 100%'), findsOneWidget);
      expect(find.text('Update'), findsNothing);
    });

    testWidgets('shows the download size of missing models', (tester) async {
      await pump(tester, downloadSize: 50 * 1024 * 1024);
      expect(find.text('Deutsch · 50.0 MB download'), findsOneWidget);
    });

    testWidgets('shows the size on this device when downloaded', (
      tester,
    ) async {
      await pump(
        tester,
        downloaded: true,
        downloadSize: 50 * 1024 * 1024,
        installedSize: 73 * 1024 * 1024,
      );
      expect(find.text('Deutsch · 73.0 MB on this device'), findsOneWidget);
    });

    testWidgets('offers an update and a delete button when outdated', (
      tester,
    ) async {
      await pump(
        tester,
        downloaded: true,
        outdated: true,
        downloadSize: 25 * 1024 * 1024,
        installedSize: 36 * 1024 * 1024,
      );
      expect(find.text('Deutsch · Update available · 25.0 MB'), findsOneWidget);
      expect(find.text('Downloaded'), findsNothing);
      await tester.tap(find.byTooltip('Update German'));
      await tester.tap(find.byTooltip('Delete German'));
      expect(taps, ['download', 'delete']);
    });

    testWidgets('disables the update when not enabled', (tester) async {
      await pump(tester, downloaded: true, outdated: true, enabled: false);
      await tester.tap(find.byTooltip('Update German'));
      await tester.tap(find.byTooltip('Delete German'));
      expect(taps, isEmpty);
    });

    testWidgets('offers no action for built-in languages', (tester) async {
      await pump(
        tester,
        downloaded: true,
        builtIn: true,
        language: const OfflineLanguage(code: 'en', name: 'English'),
      );
      expect(find.text('No download needed'), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
      expect(find.byType(IconButton), findsNothing);
    });

    testWidgets('omits a zero download size', (tester) async {
      await pump(
        tester,
        downloadSize: 0,
        language: const OfflineLanguage(code: 'xx', name: 'xx'),
      );
      expect(tester.widget<ListTile>(find.byType(ListTile)).subtitle, isNull);
    });

    testWidgets('shows progress while deleting', (tester) async {
      await pump(
        tester,
        downloaded: true,
        pending: OfflineModelOperation.delete,
      );
      expect(find.text('Deleting…'), findsOneWidget);
      expect(
        tester
            .widget<CircularProgressIndicator>(
              find.byType(CircularProgressIndicator),
            )
            .semanticsLabel,
        'Deleting…',
      );
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
