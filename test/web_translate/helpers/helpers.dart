import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/web_translate/web_translate.dart';
import 'package:translation_repository/translation_repository.dart';

const googleEngine = TranslationEngine(
  id: 'mozhi:google',
  kind: EngineKind.mozhi,
  name: 'Google',
);

const aiEngine = TranslationEngine(
  id: 'ai:openai',
  kind: EngineKind.ai,
  name: 'OpenAI',
  subtitle: 'gpt-4o',
);

const spanish = Language(code: 'es', name: 'Spanish');
const arabic = Language(code: 'ar', name: 'Arabic');

const googleToSpanish = WebTranslateSelection(
  engine: googleEngine,
  source: Language.auto,
  target: spanish,
);

/// A short page with a title, headings, a list, a quote, code and an image.
const samplePageHtml = '''
<html lang="en"><head><title>Sample page</title></head><body><article>
<h1>Sample page</h1>
<p>First paragraph of the sample page, long enough to be content.</p>
<h2>Section</h2>
<ul><li>Apples</li><li>Pears</li></ul>
<ol><li>One</li></ol>
<blockquote><p>A wise quote.</p></blockquote>
<pre>let x = 1;</pre>
<img src="/pic.jpg" alt="A picture of fruit" width="600">
<p>Last paragraph.</p>
</article></body></html>
''';

/// A [MockClient] answering every request with [html].
http.Client htmlClient(
  String html, {
  int status = 200,
  Map<String, String> headers = const {
    'content-type': 'text/html; charset=utf-8',
  },
}) => MockClient(
  (request) async => http.Response(html, status, headers: headers),
);

/// A translation repository whose [translate] is driven by [translator].
class FakeTranslationRepository extends Fake implements TranslationRepository {
  new([
    Stream<TranslationResult> Function(
      TranslationEngine engine,
      TranslationRequest request,
    )?
    translator,
  ]) : translator = translator ?? upperCaseTranslator;

  Stream<TranslationResult> Function(
    TranslationEngine engine,
    TranslationRequest request,
  )
  translator;

  final requests = <TranslationRequest>[];

  @override
  Stream<TranslationResult> translate(
    TranslationEngine engine,
    TranslationRequest request, {
    bool refresh = false,
  }) {
    requests.add(request);
    return translator(engine, request);
  }
}

TranslationResult result(
  String text, {
  bool complete = true,
  String? detected,
  TranslationEngine engine = googleEngine,
}) => TranslationResult(
  engineId: engine.id,
  engineName: engine.name,
  text: text,
  isComplete: complete,
  detectedSource: detected,
);

/// Upper-cases the text (keeping blank lines), detecting English.
Stream<TranslationResult> upperCaseTranslator(
  TranslationEngine engine,
  TranslationRequest request,
) => Stream.value(result(request.text.toUpperCase(), detected: 'en'));

class MockTranslateCubit extends MockCubit<TranslateState>
    implements TranslateCubit;

class MockWebTranslateCubit extends MockCubit<WebTranslateState>
    implements WebTranslateCubit;

/// A translate state with [engine] selected (or no engines).
TranslateState translateState({
  TranslationEngine? engine = googleEngine,
  Language target = spanish,
  Language source = Language.auto,
}) => TranslateState(
  enginesStatus: EnginesStatus.ready,
  engines: [?engine],
  engine: engine,
  sourceLanguages: const [
    Language.auto,
    Language(code: 'en', name: 'English'),
  ],
  targetLanguages: const [spanish, arabic],
  source: source,
  target: target,
);

extension PumpWebTranslate on WidgetTester {
  /// Pumps [child] in a localized app with a [TranslateCubit] and a
  /// [TranslationRepository], at [size].
  Future<void> pumpWebTranslate(
    Widget child, {
    required TranslateCubit translateCubit,
    TranslationRepository? repository,
    Size size = const Size(400, 900),
  }) async {
    view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(view.reset);
    await pumpWidget(
      RepositoryProvider<TranslationRepository>.value(
        value: repository ?? FakeTranslationRepository(),
        child: BlocProvider<TranslateCubit>.value(
          value: translateCubit,
          child: MaterialApp(
            theme: ThemeData(useMaterial3: true),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: child,
          ),
        ),
      ),
    );
  }
}

/// Answers clipboard calls; records what was copied.
class FakeClipboard {
  new(this.tester, {this.pasteText}) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        switch (call.method) {
          case 'Clipboard.setData':
            copied = (call.arguments as Map)['text'] as String?;
            return null;
          case 'Clipboard.getData':
            return pasteText == null ? null : {'text': pasteText};
          case 'Clipboard.hasStrings':
            return {'value': pasteText != null};
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

  final WidgetTester tester;
  final String? pasteText;
  String? copied;
}

/// Waits for [cubit] to reach a state matching [test].
Future<WebTranslateState> waitFor(
  WebTranslateCubit cubit,
  bool Function(WebTranslateState state) test,
) {
  if (test(cubit.state)) return Future.value(cubit.state);
  return cubit.stream.firstWhere(test).timeout(const Duration(seconds: 5));
}
