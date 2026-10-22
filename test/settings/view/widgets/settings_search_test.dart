import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/settings/models/settings_category.dart';
import 'package:mozhi/settings/view/widgets/search_highlight.dart';
import 'package:mozhi/settings/view/widgets/settings_search.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';

import '../../../helpers/helpers.dart';

void main() {
  group(SettingsSearchEntry, () {
    const entry = SettingsSearchEntry(
      category: SettingsCategory.privacy,
      anchor: 'incognito',
      title: 'Incognito',
      subtitle: "Don't save history",
      keywords: ['private'],
    );

    test('matches every word in the title, subtitle or keywords', () {
      expect(entry.matches('incog'), isTrue);
      expect(entry.matches('SAVE history'), isTrue);
      expect(entry.matches('private incognito'), isTrue);
      expect(entry.matches('private proxy'), isFalse);
      expect(entry.matches('   '), isFalse);
    });

    test('ranks title matches first, otherwise keeps the order', () {
      const proxy = SettingsSearchEntry(
        category: SettingsCategory.privacy,
        anchor: 'http_proxy',
        title: 'HTTP proxy',
        subtitle: 'Incognito-friendly',
      );
      expect(searchSettings([proxy, entry], 'incognito'), [entry, proxy]);
      expect(searchSettings([proxy, entry], 'zzz'), isEmpty);
    });
  });

  group(SettingsJump, () {
    test('is equal for the same row and serial', () {
      expect(const SettingsJump('a'), const SettingsJump('a'));
      expect(
        const SettingsJump('a').hashCode,
        const SettingsJump('a').hashCode,
      );
      expect(
        const SettingsJump('a'),
        isNot(const SettingsJump('a', serial: 1)),
      );
      expect(const SettingsJump('a'), isNot(const SettingsJump('b')));
    });
  });

  group('matchRanges', () {
    test('finds every match, ignoring case', () {
      expect(matchRanges('Banana', 'AN'), const [
        TextRange(start: 1, end: 3),
        TextRange(start: 3, end: 5),
      ]);
      expect(matchRanges('Banana', ' '), isEmpty);
      expect(matchRanges('', 'a'), isEmpty);
    });

    test('a span without matches is the plain text', () {
      final span = highlightedSpan(
        'Hello',
        'zz',
        highlight: const TextStyle(fontWeight: FontWeight.w700),
      );
      expect(span.text, 'Hello');
      expect(span.children, isNull);
    });
  });

  group(SettingsSection, () {
    testWidgets('reads a badge with its heading', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpApp(
        const Scaffold(
          body: SettingsSection(
            title: 'AI providers',
            badge: 'Advanced',
            children: [ListTile(title: Text('Row'))],
          ),
        ),
      );
      expect(find.byType(StatusBadge), findsOneWidget);
      expect(
        tester.getSemantics(find.text('Advanced')),
        isSemantics(label: 'AI providers\nAdvanced', isHeader: true),
      );
      handle.dispose();
    });

    testWidgets('without a title starts with its rows; the divider is '
        'optional', (tester) async {
      await tester.pumpApp(
        const Scaffold(
          body: Column(
            children: [
              SettingsSection(children: [ListTile(title: Text('One'))]),
              SettingsSection(
                divider: false,
                children: [ListTile(title: Text('Two'))],
              ),
            ],
          ),
        ),
      );
      expect(find.byType(Hairline), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Two')).dy,
        greaterThan(tester.getTopLeft(find.byType(Hairline)).dy),
      );
    });
  });
}
