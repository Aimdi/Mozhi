import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/history/view/widgets/history_entry_details.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/platform/web_share.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  tearDown(() => debugCanShareText = null);

  testWidgets(
    'hides Share button in HistoryEntryDetails when canShareText is false',
    (tester) async {
      final entry = HistoryEntry(
        id: '1',
        text: 'Hello',
        translation: 'Hallo',
        source: const Language(code: 'en', name: 'English'),
        target: const Language(code: 'de', name: 'German'),
        engineId: 'offline:mlkit',
        engineName: 'Offline',
        createdAt: DateTime.utc(2026, 11, 20),
      );

      debugCanShareText = false;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: HistoryEntryDetails(
              entry: entry,
              onOpen: () {},
              onToggleFavorite: () {},
              onDelete: () {},
            ),
          ),
        ),
      );
      expect(find.byTooltip('Share'), findsNothing);

      debugCanShareText = true;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: HistoryEntryDetails(
              entry: entry,
              onOpen: () {},
              onToggleFavorite: () {},
              onDelete: () {},
            ),
          ),
        ),
      );
      expect(find.byTooltip('Share'), findsOneWidget);
    },
  );
}
