import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
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

    testWidgets('uses the default setting without a SettingsCubit', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('Translate (while typing)'), findsNothing);
      expect(find.text('Translate now'), findsOneWidget);
    });
  });
}
