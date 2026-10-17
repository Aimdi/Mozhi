import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/proofread/proofread.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../helpers/helpers.dart';

class MockProofreadCubit extends MockCubit<ProofreadState>
    implements ProofreadCubit;

class MockTranslateCubit extends MockCubit<TranslateState>
    implements TranslateCubit;

class MockTranslationRepository extends Mock implements TranslationRepository;

class MockGoRouter extends Mock implements GoRouter;

class MockSettingsCubit extends MockCubit<AppSettings> implements SettingsCubit;

const openAiEngine = TranslationEngine(
  id: 'ai:openai',
  kind: EngineKind.ai,
  name: 'OpenAI',
  subtitle: 'gpt-4o',
);
const ollamaEngine = TranslationEngine(
  id: 'ai:ollama',
  kind: EngineKind.ai,
  name: 'Ollama',
  subtitle: 'llama3',
  isLocal: true,
);
const googleEngine = TranslationEngine(
  id: 'mozhi:google',
  kind: EngineKind.mozhi,
  name: 'Google',
);

const sampleInput = 'I has a apple and a orange.';
const sampleEdits = [
  ProofreadEdit(
    original: 'has',
    replacement: 'have',
    explanation: 'Subject-verb agreement.',
  ),
  ProofreadEdit(
    original: 'a apple',
    replacement: 'an apple',
    explanation: 'Use "an" before a vowel sound.',
    category: 'word_choice',
  ),
  ProofreadEdit(
    original: 'a orange',
    replacement: 'an orange',
    category: 'fact_check',
  ),
];
const sampleResult = ProofreadResult(
  correctedText: 'I have an apple and an orange.',
  edits: sampleEdits,
  summary: 'Fixed agreement and articles.',
);

const readyState = ProofreadState(
  engine: openAiEngine,
  availableEngines: [openAiEngine],
);

ProofreadState successState({Set<int> accepted = const {0, 1, 2}}) =>
    readyState.copyWith(
      input: sampleInput,
      status: ProofreadStatus.success,
      result: () => sampleResult,
      proofreadInput: sampleInput,
      acceptedEdits: accepted,
    );

const readyTranslateState = TranslateState(
  enginesStatus: EnginesStatus.ready,
  engines: [googleEngine, openAiEngine],
  engine: googleEngine,
  assistEngine: openAiEngine,
);

/// Records calls to the platform clipboard and serves [clipboardText].
class FakeClipboard {
  String? clipboardText;
  String? copied;

  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        switch (call.method) {
          case 'Clipboard.getData':
            final text = clipboardText;
            return text == null ? null : <String, dynamic>{'text': text};
          case 'Clipboard.setData':
            copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
  }
}

void stubProofreadCubit(MockProofreadCubit cubit) {
  when(cubit.proofread).thenAnswer((_) async {});
}

void setSurface(WidgetTester tester, Size size) {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

extension PumpProofread on WidgetTester {
  Future<void> pumpProofread(
    Widget child, {
    required TranslateCubit translateCubit,
    ProofreadCubit? proofreadCubit,
    TranslationRepository? repository,
    GoRouter? router,
    ThemeData? theme,
    SettingsCubit? settings,
  }) {
    Widget tree = BlocProvider<TranslateCubit>.value(
      value: translateCubit,
      child: proofreadCubit == null
          ? child
          : BlocProvider<ProofreadCubit>.value(
              value: proofreadCubit,
              child: child,
            ),
    );
    if (settings != null) {
      tree = BlocProvider<SettingsCubit>.value(value: settings, child: tree);
    }
    if (repository != null) {
      tree = RepositoryProvider<TranslationRepository>.value(
        value: repository,
        child: tree,
      );
    }
    if (router != null) {
      tree = InheritedGoRouter(goRouter: router, child: tree);
    }
    return pumpApp(tree, theme: theme);
  }
}
