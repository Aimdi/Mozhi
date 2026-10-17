import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/documents/documents.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../helpers/helpers.dart';

class MockTranslationRepository extends Mock implements TranslationRepository;

class MockTranslateCubit extends MockCubit<TranslateState>
    implements TranslateCubit;

class MockSettingsCubit extends MockCubit<AppSettings> implements SettingsCubit;

const googleEngine = TranslationEngine(
  id: 'mozhi:google',
  kind: EngineKind.mozhi,
  name: 'Google',
  subtitle: 'mozhi.example',
  mozhiEngine: 'google',
);
const deeplEngine = TranslationEngine(
  id: 'mozhi:deepl',
  kind: EngineKind.mozhi,
  name: 'DeepL',
  mozhiEngine: 'deepl',
);
const aiEngine = TranslationEngine(
  id: 'ai:openai',
  kind: EngineKind.ai,
  name: 'OpenAI',
  subtitle: 'gpt-4o-mini',
  providerId: 'openai',
);

const english = Language(code: 'en', name: 'English');
const german = Language(code: 'de', name: 'German', nativeName: 'Deutsch');
const spanish = Language(code: 'es', name: 'Spanish', nativeName: 'Español');
const french = Language(code: 'fr', name: 'French', nativeName: 'Français');

const List<Language> sourceLanguages = [
  Language.auto,
  english,
  german,
  spanish,
];
const List<Language> targetLanguages = [english, german, spanish];

const readyTranslateState = TranslateState(
  enginesStatus: EnginesStatus.ready,
  engines: [googleEngine, deeplEngine, aiEngine],
  engine: googleEngine,
  sourceLanguages: sourceLanguages,
  targetLanguages: targetLanguages,
  target: german,
);

const srtText =
    '1\n00:00:01,000 --> 00:00:02,000\nHello there.\n\n'
    '2\n00:00:03,000 --> 00:00:04,000\nGood <i>bye</i>.\n';

Uint8List bytesOf(String text) => utf8.encode(text);

TranslationResult result(String text, {bool complete = true}) =>
    TranslationResult(
      engineId: 'mozhi:google',
      engineName: 'Google',
      text: text,
      isComplete: complete,
    );

/// Registers mocktail fallbacks used by the documents tests.
void registerDocumentFallbacks() {
  registerFallbackValue(googleEngine);
  registerFallbackValue(
    const TranslationRequest(text: '', source: english, target: german),
  );
}

/// Stubs `translate` on [repository]: [respond] (default: upper-case the
/// request text) and records requests in [requests].
void stubTranslate(
  MockTranslationRepository repository, {
  List<TranslationRequest>? requests,
  Stream<TranslationResult> Function(TranslationRequest request)? respond,
}) {
  when(() => repository.translate(any(), any())).thenAnswer((invocation) {
    final request = invocation.positionalArguments[1] as TranslationRequest;
    requests?.add(request);
    return respond?.call(request) ??
        Stream.value(result(request.text.toUpperCase()));
  });
}

/// Stubs the language lists of every engine.
void stubLanguages(
  MockTranslationRepository repository, {
  List<Language> sources = sourceLanguages,
  List<Language> targets = targetLanguages,
}) {
  when(() => repository.getSourceLanguages(any()))
      .thenAnswer((_) async => sources);
  when(() => repository.getTargetLanguages(any()))
      .thenAnswer((_) async => targets);
}

/// In-memory [DocumentFileService].
class FakeDocumentFileService implements DocumentFileService {
  PickedFile? pickResult;
  Exception? pickError;
  bool saveResult = true;
  Exception? saveError;
  Exception? shareError;
  bool shareSupported = true;
  String? clipboard;
  Exception? pasteError;

  final List<List<String>> pickCalls = [];
  final List<({String fileName, Uint8List bytes, String mimeType})> saved = [];
  final List<
    ({String fileName, Uint8List bytes, String mimeType, Rect? origin})
  >
  shared = [];
  final List<String> copied = [];

  Completer<PickedFile?>? pickGate;

  @override
  Future<PickedFile?> pickFile({required List<String> extensions}) async {
    pickCalls.add(extensions);
    if (pickGate case final gate?) return await gate.future;
    if (pickError != null) throw pickError!;
    return pickResult;
  }

  @override
  Future<bool> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
  }) async {
    if (saveError != null) throw saveError!;
    saved.add((fileName: fileName, bytes: bytes, mimeType: mimeType));
    return saveResult;
  }

  @override
  bool get canShareFiles => shareSupported;

  @override
  Future<void> shareFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    Rect? origin,
  }) async {
    if (shareError != null) throw shareError!;
    shared.add((
      fileName: fileName,
      bytes: bytes,
      mimeType: mimeType,
      origin: origin,
    ));
  }

  @override
  Future<void> copyText(String text) async => copied.add(text);

  @override
  Future<String?> pasteText() async {
    if (pasteError != null) throw pasteError!;
    return clipboard;
  }
}

/// Sets the test surface size (logical pixels).
void setSurface(WidgetTester tester, Size size) {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

extension PumpDocuments on WidgetTester {
  /// Pumps [DocumentTranslatePage] with its dependencies.
  Future<void> pumpDocuments({
    required TranslateCubit translateCubit,
    required TranslationRepository repository,
    required DocumentFileService files,
    DocumentTranslator? translator,
    PickedFile? initialFile,
    String? initialText,
    SettingsCubit? settings,
  }) {
    final page = BlocProvider<TranslateCubit>.value(
      value: translateCubit,
      child: DocumentTranslatePage(
        initialFile: initialFile,
        initialText: initialText,
        fileService: files,
        translator: translator,
      ),
    );
    return pumpApp(
      RepositoryProvider<TranslationRepository>.value(
        value: repository,
        child: settings == null
            ? page
            : BlocProvider<SettingsCubit>.value(value: settings, child: page),
      ),
    );
  }
}
