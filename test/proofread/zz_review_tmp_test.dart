import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/proofread/proofread.dart';
import 'package:mozhi/proofread/widgets/widgets.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import 'helpers/proofread_helpers.dart';

void main() {
  testWidgets(skip: true, 'tmp: level label truncation at 360dp', (tester) async {
    final cubit = MockProofreadCubit();
    final translate = MockTranslateCubit();
    stubProofreadCubit(cubit);
    setSurface(tester, const Size(360, 800));
    whenListen(
      cubit,
      const Stream<ProofreadState>.empty(),
      initialState: readyState,
    );
    whenListen(
      translate,
      const Stream<TranslateState>.empty(),
      initialState: readyTranslateState,
    );
    await tester.pumpProofread(
      const ProofreadView(),
      translateCubit: translate,
      proofreadCubit: cubit,
    );
    final p = tester.renderObject<RenderParagraph>(find.text('Comprehensive'));
    // ignore: avoid_print
    print(
      'TMP comprehensive exceeded=${p.didExceedMaxLines} '
      'width=${p.size.width}',
    );
    final handle = tester.ensureSemantics();
    await tester.enterText(find.byKey(const Key('proofread_input')), 'abc');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    final node = tester.getSemantics(find.byKey(const Key('proofread_input')));
    // ignore: avoid_print
    print(
      'TMP input semantics label="${node.label}" '
      'value="${node.value}" hint="${node.hint}"',
    );
    handle.dispose();
  });

  testWidgets('tmp: stale edit sheet toggles new result', (tester) async {
    final cubit = MockProofreadCubit();
    final translate = MockTranslateCubit();
    stubProofreadCubit(cubit);
    setSurface(tester, const Size(800, 2400));
    final controller = StreamController<ProofreadState>();
    addTearDown(controller.close);
    final loading = successState().copyWith(status: ProofreadStatus.loading);
    whenListen(cubit, controller.stream, initialState: loading);
    whenListen(
      translate,
      const Stream<TranslateState>.empty(),
      initialState: readyTranslateState,
    );
    await tester.pumpProofread(
      const ProofreadView(),
      translateCubit: translate,
      proofreadCubit: cubit,
    );
    final element = tester.element(find.byType(ProofreadResultCard));
    unawaited(showProofreadEditSheet(element, 1));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Use "an" before a vowel sound.'), findsWidgets);
    const other = ProofreadResult(
      correctedText: 'x',
      edits: [
        ProofreadEdit(original: 'I', replacement: 'We'),
        ProofreadEdit(original: 'apple', replacement: 'pear'),
      ],
    );
    final next = successState().copyWith(
      result: () => other,
      acceptedEdits: {0, 1},
    );
    when(() => cubit.state).thenReturn(next);
    controller.add(next);
    await tester.pump();
    // Sheet still shows the old edit.
    expect(find.text('Use "an" before a vowel sound.'), findsWidgets);
    await tester.tap(find.text('Revert edit'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    verify(() => cubit.toggleEdit(1)).called(1);
    // ignore: avoid_print
    print('TMP sheet toggled index 1 of the NEW result (apple->pear)');
  });
}
