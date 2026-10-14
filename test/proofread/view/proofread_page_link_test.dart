import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/proofread/proofread.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/proofread_helpers.dart';

void main() {
  late MockTranslateCubit translateCubit;
  late MockTranslationRepository repository;

  setUpAll(() {
    registerFallbackValue(openAiEngine);
    registerFallbackValue(WritingStyle.general);
    registerFallbackValue(CorrectionLevel.standard);
    registerFallbackValue(Formality.automatic);
  });

  setUp(() {
    translateCubit = MockTranslateCubit();
    repository = MockTranslationRepository();
    whenListen(
      translateCubit,
      const Stream<TranslateState>.empty(),
      initialState: readyTranslateState,
    );
  });

  Future<void> pumpPage(WidgetTester tester, String? text) async {
    setSurface(tester, const Size(800, 2400));
    await tester.pumpProofread(
      ProofreadPage(initialText: text),
      translateCubit: translateCubit,
      repository: repository,
    );
  }

  ProofreadState proofreadState(WidgetTester tester) =>
      tester.element(find.byType(ProofreadView)).read<ProofreadCubit>().state;

  String fieldText(WidgetTester tester) => tester
      .widget<TextField>(find.byKey(const Key('proofread_input')))
      .controller!
      .text;

  void verifyNoProofread() => verifyNever(
    () => repository.proofread(
      any(),
      any(),
      style: any(named: 'style'),
      level: any(named: 'level'),
      formality: any(named: 'formality'),
      context: any(named: 'context'),
      uiLanguage: any(named: 'uiLanguage'),
    ),
  );

  group('ProofreadPage link text', () {
    testWidgets('fills the input without proofreading', (tester) async {
      await pumpPage(tester, 'I has a apple.');
      await tester.pump();

      expect(proofreadState(tester).input, 'I has a apple.');
      expect(proofreadState(tester).status, ProofreadStatus.idle);
      expect(fieldText(tester), 'I has a apple.');
      verifyNoProofread();
    });

    testWidgets('cuts long text to the external input limit', (tester) async {
      await pumpPage(tester, 'a' * 9000);

      expect(
        proofreadState(tester).input,
        hasLength(ProofreadPage.maxLinkTextLength),
      );
      expect(
        ProofreadPage.maxLinkTextLength,
        TranslateCubit.maxExternalInputLength,
      );
    });

    testWidgets('does not split a surrogate pair', (tester) async {
      final text = '${'a' * (ProofreadPage.maxLinkTextLength - 1)}😀b';
      await pumpPage(tester, text);

      expect(
        proofreadState(tester).input,
        'a' * (ProofreadPage.maxLinkTextLength - 1),
      );
    });

    testWidgets('ignores missing or blank text', (tester) async {
      await pumpPage(tester, '   ');
      expect(proofreadState(tester).input, isEmpty);
    });

    testWidgets('applies new link text but keeps edits otherwise', (
      tester,
    ) async {
      await pumpPage(tester, 'first');
      expect(proofreadState(tester).input, 'first');

      await tester.enterText(
        find.byKey(const Key('proofread_input')),
        'edited',
      );
      await pumpPage(tester, 'first');
      expect(proofreadState(tester).input, 'edited');

      await pumpPage(tester, null);
      expect(proofreadState(tester).input, 'edited');

      await pumpPage(tester, 'second');
      await tester.pump();
      expect(proofreadState(tester).input, 'second');
      expect(fieldText(tester), 'second');
      verifyNoProofread();
    });
  });
}
