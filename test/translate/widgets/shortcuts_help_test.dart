import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/view/app_shell.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/widgets/shortcuts_help.dart';

import '../../helpers/helpers.dart';
import '../../settings/view/helpers.dart' show createSettingsCubit;

void main() {
  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  group('translateShortcutHelp', () {
    test('lists no plain Enter with multiline input on (the default)', () {
      final rows = translateShortcutHelp(l10n, command: false, web: false);
      expect(rows.map((r) => r.keys), isNot(contains('Enter')));
      expect(
        rows.map((r) => r.description),
        isNot(contains('Translate (while typing)')),
      );
      // Shift+Enter is only the Listen button's.
      expect(
        rows.where((r) => r.keys == 'Shift + Enter').map((r) => r.description),
        ['Listen slowly (on a focused Listen button)'],
      );
    });

    test('says Enter translates and Shift+Enter adds a line with multiline '
        'input off', () {
      final rows = translateShortcutHelp(
        l10n,
        command: false,
        web: false,
        multilineInput: false,
      );
      expect(rows.take(3).map((r) => (r.keys, r.description)), [
        ('Ctrl + Enter', 'Translate now'),
        ('Enter', 'Translate (while typing)'),
        ('Shift + Enter', 'Insert a new line (while typing)'),
      ]);
      expect(rows[1].keysSemantics, 'Enter');
      expect(rows[2].keysSemantics, 'Shift Enter');
      // The Listen button's Shift+Enter is still listed.
      expect(
        rows.map((r) => r.description),
        contains('Listen slowly (on a focused Listen button)'),
      );
      expect(
        rows.length,
        translateShortcutHelp(l10n, command: false, web: false).length + 2,
      );
    });

    test('keeps the keys on Apple platforms', () {
      final rows = translateShortcutHelp(
        l10n,
        command: true,
        web: false,
        multilineInput: false,
      );
      expect(rows.take(3).map((r) => r.keys), [
        '⌘ + Enter',
        'Enter',
        'Shift + Enter',
      ]);
    });
  });

  group('appShortcutHelp', () {
    test('lists the tabs and History, as the app shell binds them', () {
      final rows = appShortcutHelp(l10n, command: false);
      expect(rows.map((r) => (r.keys, r.keysSemantics, r.description)), [
        ('Ctrl + Shift + 1…4', 'Control Shift 1 to 4', 'Switch to tab 1 to 4'),
        ('Ctrl + Shift + H', 'Control Shift H', 'Open History'),
      ]);
      expect(AppShell.tabShortcuts, hasLength(4));
      // Ctrl, also on Apple platforms (what the shell asks for).
      final apple = appShortcutHelp(l10n, command: true);
      expect(apple.map((r) => r.keys), [
        'Ctrl + Shift + 1…4',
        'Ctrl + Shift + H',
      ]);
    });
  });

  group(TranslateShortcutsDialog, () {
    Future<void> pump(WidgetTester tester, {AppSettings? settings}) async {
      const dialog = TranslateShortcutsDialog();
      await tester.pumpApp(
        settings == null
            ? dialog
            : BlocProvider<SettingsCubit>.value(
                value: createSettingsCubit(settings),
                child: dialog,
              ),
      );
    }

    testWidgets('mentions Enter and Shift+Enter with multiline input off', (
      tester,
    ) async {
      await pump(tester, settings: const AppSettings(multilineInput: false));
      expect(find.text('Enter'), findsOneWidget);
      expect(find.text('Translate (while typing)'), findsOneWidget);
      expect(find.text('Insert a new line (while typing)'), findsOneWidget);
      expect(find.text('Shift + Enter'), findsNWidgets(2));
      expect(tester.widget<Text>(find.text('Enter')).semanticsLabel, 'Enter');
    });

    testWidgets('keeps the list with multiline input on', (tester) async {
      await pump(tester, settings: const AppSettings());
      expect(find.text('Enter'), findsNothing);
      expect(find.text('Translate (while typing)'), findsNothing);
      expect(find.text('Shift + Enter'), findsOneWidget);
      expect(find.text('Translate now'), findsOneWidget);
    });

    testWidgets('lists the translate screen, then the whole app', (
      tester,
    ) async {
      await pump(tester);
      final translate = tester.getRect(find.text('Translate'));
      final app = tester.getRect(find.text('Anywhere in the app'));
      expect(app.top, greaterThan(translate.top));
      expect(
        tester.getRect(find.text('Go to the text box')).top,
        allOf(greaterThan(translate.top), lessThan(app.top)),
      );
      for (final keys in ['Ctrl + Shift + 1…4', 'Ctrl + Shift + H']) {
        expect(tester.getRect(find.text(keys)).top, greaterThan(app.top));
      }
      expect(find.text('Open History'), findsOneWidget);
    });

    testWidgets('is a table: keys, then their descriptions beside them', (
      tester,
    ) async {
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = const Size(1200, 900);
      addTearDown(tester.view.reset);
      await pump(tester);
      final descriptions = [
        'Translate now',
        'Show keyboard shortcuts',
        'Listen slowly (on a focused Listen button)',
        'Open History',
      ].map((text) => tester.getRect(find.text(text))).toList();
      // One column: the descriptions start at the same place, after the
      // widest keys, on their keys' line.
      for (final rect in descriptions) {
        expect(rect.left, descriptions.first.left);
      }
      expect(
        descriptions.first.left,
        greaterThan(tester.getRect(find.text('? or Ctrl + /')).right),
      );
      final keys = tester.getRect(find.text('Ctrl + Enter'));
      expect(descriptions.first.top, lessThan(keys.bottom));
      // Each row is read as one.
      expect(
        find.bySemanticsLabel(RegExp(r'^Control Enter\s+Translate now')),
        findsOneWidget,
      );
    });

    testWidgets('puts descriptions under their keys when narrow', (
      tester,
    ) async {
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = const Size(320, 900);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: const TranslateShortcutsDialog(),
        ),
      );
      expect(tester.takeException(), isNull);
      final keys = tester.getRect(find.text('Ctrl + Enter'));
      final description = tester.getRect(find.text('Translate now'));
      expect(description.top, greaterThanOrEqualTo(keys.bottom));
    });

    testWidgets('uses the default setting without a SettingsCubit', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('Translate (while typing)'), findsNothing);
      expect(find.text('Translate now'), findsOneWidget);
    });
  });
}
