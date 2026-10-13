// Temporary visual check; deleted after use.
// ignore_for_file: avoid_print, prefer_const_constructors
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/proofread/proofread.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import 'helpers/proofread_helpers.dart';

const _out =
    '/tmp/claude-0/-home-user-Mozhi/071da89e-592f-547c-b32a-54fb03071e39/scratchpad';

Future<void> _loadFonts() async {
  const dir = '/opt/flutter-sdk/flutter/bin/cache/artifacts/material_fonts';
  final roboto = FontLoader('Roboto');
  for (final f in [
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
  ]) {
    roboto.addFont(
      Future.value(ByteData.sublistView(File('$dir/$f').readAsBytesSync())),
    );
  }
  await roboto.load();
  final icons = FontLoader('MaterialIcons')
    ..addFont(
      Future.value(
        ByteData.sublistView(
          File('$dir/MaterialIcons-Regular.otf').readAsBytesSync(),
        ),
      ),
    );
  await icons.load();
}

void main() {
  const longInput =
      'Their going too the park tomorow, and they has a apple. Me and him '
      'was planning to bring alot of snacks, but we forgot to buy them.';
  const result = ProofreadResult(
    correctedText:
        "They're going to the park tomorrow, and they have an apple. He and I "
        'were planning to bring a lot of snacks, but we forgot to buy them.',
    edits: [
      ProofreadEdit(
        original: 'Their',
        replacement: "They're",
        explanation:
            '"Their" is possessive; you need the contraction of "they are".',
      ),
      ProofreadEdit(
        original: 'too',
        replacement: 'to',
        category: 'spelling',
        explanation: '"Too" means "also".',
      ),
      ProofreadEdit(
        original: 'tomorow',
        replacement: 'tomorrow',
        category: 'spelling',
      ),
      ProofreadEdit(
        original: 'has a apple',
        replacement: 'have an apple',
        explanation: 'Agreement and article.',
      ),
      ProofreadEdit(
        original: 'Me and him was',
        replacement: 'He and I were',
        explanation: 'Subject pronouns and plural verb.',
      ),
      ProofreadEdit(
        original: 'alot',
        replacement: 'a lot',
        category: 'spelling',
      ),
    ],
    summary:
        'Several spelling and agreement issues; the tone is casual and clear.',
  );

  for (final dark in [false, true]) {
    for (final size in [const Size(412, 1500), const Size(1280, 900)]) {
      testWidgets('shot dark=$dark ${size.width}', (tester) async {
        await tester.runAsync(_loadFonts);
        final cubit = MockProofreadCubit();
        final translate = MockTranslateCubit();
        final state = ProofreadState(
          input: longInput,
          engine: openAiEngine,
          availableEngines: const [openAiEngine, ollamaEngine],
          status: ProofreadStatus.success,
          result: result,
          proofreadInput: longInput,
          acceptedEdits: const {0, 1, 2, 4, 5},
        );
        whenListen(
          cubit,
          const Stream<ProofreadState>.empty(),
          initialState: state,
        );
        whenListen(
          translate,
          const Stream<TranslateState>.empty(),
          initialState: readyTranslateState,
        );
        setSurface(tester, size);
        await tester.pumpProofread(
          const ProofreadView(),
          translateCubit: translate,
          proofreadCubit: cubit,
          theme: ThemeData(
            useMaterial3: true,
            fontFamily: 'Roboto',
            brightness: dark ? Brightness.dark : Brightness.light,
            colorSchemeSeed: const Color(0xFF3F51B5),
          ),
        );
        await tester.pumpAndSettle();
        final element = find.byType(ProofreadView).evaluate().single;
        await tester.runAsync(() async {
          final image = await captureImage(element);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          File(
            '$_out/proofread_${dark ? 'dark' : 'light'}_${size.width.toInt()}.png',
          ).writeAsBytesSync(bytes!.buffer.asUint8List());
        });
      });
    }
  }
}
