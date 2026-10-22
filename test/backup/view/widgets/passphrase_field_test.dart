import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/backup/view/widgets/passphrase_field.dart';

import '../../../helpers/helpers.dart';

void main() {
  group(PassphraseStrength, () {
    test('rates by length and words', () {
      for (final (passphrase, strength) in [
        ('', PassphraseStrength.tooShort),
        ('abc 123', PassphraseStrength.tooShort),
        ('abcdefgh', PassphraseStrength.weak),
        ('hunter2hunter', PassphraseStrength.weak),
        ('correct horse battery', PassphraseStrength.fair),
        ('abcdefghijklmn', PassphraseStrength.fair),
        ('cat dog sun sky', PassphraseStrength.fair),
        ('correct horse battery staple', PassphraseStrength.strong),
        ('café-niño-über-straße', PassphraseStrength.strong),
        ('abcdefghijklmnopqrstuvwx', PassphraseStrength.strong),
      ]) {
        expect(PassphraseStrength.of(passphrase), strength, reason: passphrase);
      }
      expect(PassphraseStrength.tooShort.acceptable, isFalse);
      expect(PassphraseStrength.weak.acceptable, isTrue);
    });

    test('counts characters, not UTF-16 units', () {
      // Seven emoji: 14 UTF-16 code units.
      expect(PassphraseStrength.of('😀' * 7), PassphraseStrength.tooShort);
      expect(PassphraseStrength.of('😀' * 8), PassphraseStrength.weak);
    });
  });

  group(PassphraseField, () {
    testWidgets('hides the passphrase until shown and keeps keyboards from '
        'learning it', (tester) async {
      final controller = TextEditingController(text: 'secret words');
      addTearDown(controller.dispose);
      await tester.pumpApp(
        Scaffold(body: PassphraseField(controller: controller)),
      );

      TextField field() => tester.widget<TextField>(find.byType(TextField));
      expect(field().obscureText, isTrue);
      expect(field().autocorrect, isFalse);
      expect(field().enableSuggestions, isFalse);
      expect(field().enableIMEPersonalizedLearning, isFalse);
      expect(field().autofillHints, [AutofillHints.password]);
      expect(find.text('Passphrase'), findsOneWidget);

      await tester.tap(find.byTooltip('Show passphrase'));
      await tester.pump();
      expect(field().obscureText, isFalse);
      await tester.tap(find.byTooltip('Hide passphrase'));
      await tester.pump();
      expect(field().obscureText, isTrue);
    });

    testWidgets('a new passphrase is offered to password managers and '
        'stays one line', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpApp(
        Scaffold(
          body: PassphraseField(
            controller: controller,
            newPassphrase: true,
            label: 'Repeat',
            enabled: false,
          ),
        ),
      );

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.autofillHints, [AutofillHints.newPassword]);
      expect(find.text('Repeat'), findsOneWidget);
      expect(
        tester.widget<IconButton>(find.byType(IconButton)).onPressed,
        isNull,
      );
      final formatter = field.inputFormatters!.single;
      expect(
        formatter
            .formatEditUpdate(
              TextEditingValue.empty,
              const TextEditingValue(text: 'a\nb'),
            )
            .text,
        'ab',
      );
    });
  });

  group(PassphraseStrengthHint, () {
    Future<void> pump(WidgetTester tester, String passphrase) => tester.pumpApp(
      Scaffold(body: PassphraseStrengthHint(passphrase: passphrase)),
    );

    testWidgets('shows nothing for an empty passphrase', (tester) async {
      await pump(tester, '');
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('says how strong the passphrase is', (tester) async {
      for (final (passphrase, text) in [
        ('short', 'Use at least 8 characters'),
        ('abcdefgh', 'Weak: easy to guess. Use 4 or more random words.'),
        (
          'correct horse battery',
          'Fair. 4 or more random words would be stronger.',
        ),
        ('correct horse battery staple', 'Strong'),
      ]) {
        await pump(tester, passphrase);
        expect(find.text(text), findsOneWidget, reason: passphrase);
        expect(
          find.bySemanticsLabel('Passphrase strength: $text'),
          findsOneWidget,
        );
      }
    });
  });
}
