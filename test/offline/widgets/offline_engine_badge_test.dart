import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/offline/offline.dart';

import '../../helpers/helpers.dart';

void main() {
  group('OfflineEngineBadge', () {
    testWidgets('shows an "Offline" label with a tooltip', (tester) async {
      // A non-const instance so the constructor is covered.
      // ignore: prefer_const_constructors
      await tester.pumpApp(Center(child: OfflineEngineBadge()));
      expect(find.text('Offline'), findsOneWidget);
      expect(find.byIcon(OfflineEngineBadge.icon), findsOneWidget);
      expect(find.byTooltip('Translated on this device'), findsOneWidget);
    });

    testWidgets('compact shows only a labelled icon', (tester) async {
      await tester.pumpApp(
        const Center(child: OfflineEngineBadge(compact: true)),
      );
      expect(find.text('Offline'), findsNothing);
      expect(find.bySemanticsLabel('Offline'), findsOneWidget);
      expect(find.byTooltip('Translated on this device'), findsOneWidget);
    });

    testWidgets(
      'exposes tooltip via semantics without blocking sibling merge',
      (tester) async {
        final handle = tester.ensureSemantics();
        await tester.pumpApp(
          const MergeSemantics(
            child: Column(children: [Text('English'), OfflineEngineBadge()]),
          ),
        );
        final semantics = tester.getSemantics(find.byType(Column));
        expect(
          semantics.label.split('\n'),
          containsAll(['English', 'Offline']),
        );
        expect(semantics.tooltip, 'Translated on this device');
        expect(semantics.hint, isEmpty);
        handle.dispose();
      },
    );
  });
}
