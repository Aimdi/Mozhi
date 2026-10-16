import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/view/widgets/empty_state_view.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';

void main() {
  final theme = ThemeData(colorSchemeSeed: const Color(0xFF3F51B5));

  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
    MaterialApp(
      theme: theme,
      localizationsDelegates: appLocalizationsDelegates,
      home: Scaffold(body: child),
    ),
  );

  Color circleColor(WidgetTester tester) {
    final box = tester.widget<DecoratedBox>(
      find
          .descendant(
            of: find.byType(EmptyStateView),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    return (box.decoration as BoxDecoration).color!;
  }

  group('EmptyStateView', () {
    testWidgets('shows the icon, title, body and action', (tester) async {
      var tapped = false;
      await pump(
        tester,
        EmptyStateView(
          icon: Icons.history,
          title: 'Nothing here',
          body: 'Your things will appear here.',
          action: FilledButton(
            onPressed: () => tapped = true,
            child: const Text('Do it'),
          ),
        ),
      );
      expect(find.byIcon(Icons.history), findsOneWidget);
      expect(find.text('Your things will appear here.'), findsOneWidget);
      expect(
        tester.getSemantics(find.text('Nothing here')),
        isSemantics(isHeader: true, isLiveRegion: false),
      );
      expect(circleColor(tester), theme.colorScheme.primaryContainer);
      await tester.tap(find.text('Do it'));
      expect(tapped, isTrue);
    });

    testWidgets('error tone and live region', (tester) async {
      await pump(
        tester,
        const EmptyStateView(
          icon: Icons.error_outline,
          title: 'Failed',
          tone: EmptyStateTone.error,
          announce: true,
          compact: true,
        ),
      );
      expect(circleColor(tester), theme.colorScheme.errorContainer);
      expect(
        tester.getSemantics(find.text('Failed')),
        isSemantics(isHeader: true, isLiveRegion: true),
      );
      final circle = find.ancestor(
        of: find.byIcon(Icons.error_outline),
        matching: find.byType(SizedBox),
      );
      expect(tester.getSize(circle.first).width, 64);
    });
  });

  group('SettingsIcon', () {
    Color iconColor(WidgetTester tester) =>
        tester.widget<Icon>(find.byIcon(Icons.tune)).color!;

    testWidgets('is primary in an enabled tile', (tester) async {
      await pump(
        tester,
        const ListTile(leading: SettingsIcon(Icons.tune), title: Text('A')),
      );
      expect(iconColor(tester), theme.colorScheme.primary);
    });

    testWidgets('takes a given colour', (tester) async {
      await pump(
        tester,
        ListTile(
          leading: SettingsIcon(Icons.tune, color: theme.colorScheme.error),
          title: const Text('A'),
        ),
      );
      expect(iconColor(tester), theme.colorScheme.error);
    });

    testWidgets('is greyed out in a disabled tile', (tester) async {
      await pump(
        tester,
        ListTile(
          enabled: false,
          leading: SettingsIcon(Icons.tune, color: theme.colorScheme.error),
          title: const Text('A'),
        ),
      );
      expect(iconColor(tester), isNot(theme.colorScheme.primary));
      expect(iconColor(tester), isNot(theme.colorScheme.error));
    });
  });

  testWidgets('SettingsDangerDivider is a divider', (tester) async {
    await pump(tester, const SettingsDangerDivider());
    expect(find.byType(Divider), findsOneWidget);
  });
}
