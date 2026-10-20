import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/tab_hero.dart';
import 'package:mozhi/core/widgets/x_ui.dart';

import '../../helpers/helpers.dart';

void main() {
  group('TabHero', () {
    testWidgets('centres a bold header title under a decorative icon', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpApp(
        const Center(
          child: TabHero(
            icon: Icons.menu_book_rounded,
            title: 'What does this mean?',
            body: 'Definitions and examples.',
            child: Text('child'),
          ),
        ),
      );

      final title = tester.widget<Text>(find.text('What does this mean?'));
      expect(title.textAlign, TextAlign.center);
      expect(title.style?.fontWeight, FontWeight.w800);
      expect(
        tester.getSemantics(find.text('What does this mean?')),
        isSemantics(label: 'What does this mean?', isHeader: true),
      );
      final context = tester.element(find.byType(TabHero));
      final icon = tester.widget<Icon>(find.byIcon(Icons.menu_book_rounded));
      expect(icon.size, TabHero.iconSize);
      expect(icon.color, Theme.of(context).colorScheme.primary);
      expect(
        find.ancestor(
          of: find.byIcon(Icons.menu_book_rounded),
          matching: find.byType(ExcludeSemantics),
        ),
        findsWidgets,
      );
      final body = tester.widget<Text>(find.text('Definitions and examples.'));
      expect(body.style?.color, AppPalette.of(context).secondaryText);
      // Icon, title, body and child from top to bottom.
      final ys = [
        find.byIcon(Icons.menu_book_rounded),
        find.text('What does this mean?'),
        find.text('Definitions and examples.'),
        find.text('child'),
      ].map((finder) => tester.getCenter(finder).dy).toList();
      expect(ys, orderedEquals([...ys]..sort()));
      handle.dispose();
    });

    testWidgets('can be just a title', (tester) async {
      await tester.pumpApp(const TabHero(title: "Let's talk!"));
      expect(find.text("Let's talk!"), findsOneWidget);
      expect(find.byType(Icon), findsNothing);
      expect(find.byType(Text), findsOneWidget);
    });
  });
}
