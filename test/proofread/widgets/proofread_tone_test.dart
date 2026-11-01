import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/proofread/proofread.dart';
import 'package:mozhi/proofread/widgets/widgets.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/proofread_helpers.dart';

void main() {
  late MockProofreadCubit cubit;
  late MockTranslateCubit translateCubit;

  setUpAll(() => registerFallbackValue(WritingTone.automatic));

  setUp(() {
    cubit = MockProofreadCubit();
    translateCubit = MockTranslateCubit();
    stubProofreadCubit(cubit);
    whenListen(
      translateCubit,
      const Stream<TranslateState>.empty(),
      initialState: readyTranslateState,
    );
  });

  Future<void> pumpControls(
    WidgetTester tester,
    ProofreadState state, {
    ThemeData? theme,
    double width = 760,
  }) async {
    setSurface(tester, const Size(800, 1600));
    whenListen(
      cubit,
      const Stream<ProofreadState>.empty(),
      initialState: state,
    );
    await tester.pumpProofread(
      Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: width, child: const ProofreadControls()),
        ),
      ),
      translateCubit: translateCubit,
      proofreadCubit: cubit,
      theme: theme,
    );
  }

  Finder toneMenu() => find.byKey(const Key('proofread_tone_menu'));

  group('tone selector', () {
    testWidgets('shows the tone beside the writing style', (tester) async {
      await pumpControls(tester, readyState);
      expect(
        find.descendant(of: toneMenu(), matching: find.text('Tone')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: toneMenu(), matching: find.text('Automatic')),
        findsOneWidget,
      );
      final style = tester.getRect(
        find.byKey(const Key('proofread_style_menu')),
      );
      final tone = tester.getRect(toneMenu());
      expect(tone.top, style.top);
      expect(tone.height, greaterThanOrEqualTo(48));
    });

    testWidgets('lists every tone with its description and picks one', (
      tester,
    ) async {
      await pumpControls(tester, readyState);
      await tester.tap(toneMenu());
      await tester.pumpAndSettle();
      for (final label in [
        'Enthusiastic',
        'Friendly',
        'Confident',
        'Diplomatic',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('Keep your own tone'), findsOneWidget);
      expect(find.text('Energetic and positive'), findsOneWidget);
      expect(find.text('Warm and approachable'), findsOneWidget);
      expect(find.text('Assertive, without hedging'), findsOneWidget);
      expect(find.text('Tactful and constructive'), findsOneWidget);
      await tester.tap(find.text('Diplomatic'));
      await tester.pumpAndSettle();
      verify(() => cubit.setTone(WritingTone.diplomatic)).called(1);
    });

    testWidgets('marks the chosen tone as selected', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpControls(
        tester,
        readyState.copyWith(tone: WritingTone.confident),
      );
      expect(
        find.descendant(of: toneMenu(), matching: find.text('Confident')),
        findsOneWidget,
      );
      await tester.tap(toneMenu());
      await tester.pumpAndSettle();
      // A tone with a description reads as both lines.
      expect(
        tester.getSemantics(
          find.descendant(
            of: find.byType(MenuItemButton),
            matching: find.text('Confident'),
          ),
        ),
        isSemantics(
          label: 'Confident\nAssertive, without hedging',
          isSelected: true,
          isInMutuallyExclusiveGroup: true,
        ),
      );
      expect(
        tester.getSemantics(find.text('Friendly')),
        isSemantics(
          label: 'Friendly\nWarm and approachable',
          isSelected: false,
          isInMutuallyExclusiveGroup: true,
        ),
      );
      semantics.dispose();
    });

    testWidgets('updates when the tone changes', (tester) async {
      setSurface(tester, const Size(800, 1600));
      whenListen(
        cubit,
        Stream.value(readyState.copyWith(tone: WritingTone.friendly)),
        initialState: readyState,
      );
      await tester.pumpProofread(
        const Scaffold(body: ProofreadControls()),
        translateCubit: translateCubit,
        proofreadCubit: cubit,
      );
      await tester.pump();
      expect(
        find.descendant(of: toneMenu(), matching: find.text('Friendly')),
        findsOneWidget,
      );
    });

    for (final (name, look, radius) in [
      ('classic', AppLook.classic, 28.0),
      ('terminal', AppLook.terminal, 0.0),
    ]) {
      for (final brightness in Brightness.values) {
        testWidgets('follows the $name look (${brightness.name})', (
          tester,
        ) async {
          await pumpControls(
            tester,
            readyState,
            theme: buildAppTheme(
              ColorScheme.fromSeed(
                seedColor: Colors.indigo,
                brightness: brightness,
              ),
              look: look,
            ),
          );
          Material tileMaterial(Finder menu) => tester.widget<Material>(
            find.descendant(of: menu, matching: find.byType(Material)).first,
          );
          final tone =
              tileMaterial(toneMenu()).shape! as RoundedRectangleBorder;
          final style =
              tileMaterial(find.byKey(const Key('proofread_style_menu'))).shape!
                  as RoundedRectangleBorder;
          expect(tone, style);
          expect(tone.borderRadius, BorderRadius.circular(radius));
          expect(tester.takeException(), isNull);
        });
      }
    }
  });

  group('options badge', () {
    test('counts a tone as a changed option', () {
      expect(proofreadOptionsModified(readyState), isFalse);
      expect(
        proofreadOptionsModified(
          readyState.copyWith(tone: WritingTone.enthusiastic),
        ),
        isTrue,
      );
    });
  });

  group('labels', () {
    testWidgets('name and describe every tone', (tester) async {
      await tester.pumpProofread(
        const SizedBox(),
        translateCubit: translateCubit,
      );
      final l10n = tester.element(find.byType(SizedBox)).l10n;
      for (final tone in WritingTone.values) {
        expect(l10n.proofreadWritingTone(tone), isNotEmpty);
        expect(l10n.proofreadToneDescription(tone), isNotEmpty);
      }
    });
  });
}
