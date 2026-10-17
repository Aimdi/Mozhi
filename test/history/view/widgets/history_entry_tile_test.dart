import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/history/view/widgets/history_entry_tile.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../../helpers/helpers.dart';

final _entry = HistoryEntry(
  id: '1',
  text: 'Bonjour',
  translation: 'Hello',
  source: Language.auto,
  target: const Language(code: 'en', name: 'English'),
  engineId: 'mozhi:google',
  engineName: 'Google',
  createdAt: DateTime.now(),
  detectedSource: 'fr',
);

const _pair = '\u2068French (detected)\u2069 → \u2068English\u2069';

void main() {
  group(HistoryEntryTile, () {
    Future<void> pump(WidgetTester tester, double width) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpApp(
        Scaffold(
          body: ListView(
            children: [
              HistoryEntryTile(
                entry: _entry,
                onTap: () {},
                onToggleFavorite: () {},
                onDelete: () {},
              ),
            ],
          ),
        ),
      );
    }

    testWidgets('puts the pair and the meta on one line when they fit', (
      tester,
    ) async {
      await pump(tester, 800);
      expect(find.text(_pair), findsOneWidget);
      expect(find.text(' · Google · now'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text(' · Google · now')).dy,
        tester.getTopLeft(find.text(_pair)).dy,
      );
    });

    testWidgets('moves the meta below a pair that would be cut', (
      tester,
    ) async {
      await pump(tester, 400);
      expect(tester.takeException(), isNull);
      final pair = tester.renderObject<RenderParagraph>(find.text(_pair));
      expect(pair.didExceedMaxLines, isFalse);
      expect(find.text('Google · now'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Google · now')).dy,
        greaterThan(tester.getTopLeft(find.text(_pair)).dy),
      );
    });
  });
}
