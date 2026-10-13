import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/offline/offline.dart';

import '../../helpers/helpers.dart';

void main() {
  group('OfflineEngineBadge', () {
    testWidgets('shows an "Offline" label with a tooltip', (tester) async {
      await tester.pumpApp(const Center(child: OfflineEngineBadge()));
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
  });
}
