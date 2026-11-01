import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/documents/documents.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/fakes.dart';

typedef _Share = ({
  String? id,
  PickedFile? file,
  ({String? name, bool tooLarge})? unavailable,
});

void main() {
  late MockTranslateCubit translateCubit;
  late MockTranslationRepository repository;
  late FakeDocumentFileService files;
  late List<Completer<void>> gates;
  late ValueNotifier<_Share> share;

  setUpAll(registerDocumentFallbacks);

  setUp(() {
    translateCubit = MockTranslateCubit();
    repository = MockTranslationRepository();
    files = FakeDocumentFileService();
    gates = [];
    share = ValueNotifier((id: null, file: null, unavailable: null));
    stubTranslate(
      repository,
      respond: (request) {
        final gate = Completer<void>();
        gates.add(gate);
        return Stream.fromFuture(
          gate.future.then((_) => result(request.text.toUpperCase())),
        );
      },
    );
    stubLanguages(repository);
    whenListen(
      translateCubit,
      const Stream<TranslateState>.empty(),
      initialState: readyTranslateState,
    );
  });

  tearDown(() {
    for (final gate in gates) {
      if (!gate.isCompleted) gate.complete();
    }
  });

  PickedFile file(String name, String text) =>
      PickedFile(name: name, bytes: Uint8List.fromList(text.codeUnits));

  /// Lets dialogs and routes come and go (the progress indicator of a
  /// running translation never settles).
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// The home screen, with a button that opens the document screen (which
  /// follows [share]).
  Future<void> pumpHome(WidgetTester tester) async {
    setSurface(tester, const Size(600, 3000));
    await tester.pumpWidget(
      RepositoryProvider<TranslationRepository>.value(
        value: repository,
        child: BlocProvider<TranslateCubit>.value(
          value: translateCubit,
          child: MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ValueListenableBuilder(
                        valueListenable: share,
                        builder: (context, value, _) => DocumentTranslatePage(
                          shareId: value.id,
                          initialFile: value.file,
                          unavailableFile: value.unavailable,
                          fileService: files,
                          translator: DocumentTranslator(
                            repository: repository,
                            maxAttempts: 1,
                            retryDelay: Duration.zero,
                          ),
                        ),
                      ),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await settle(tester);
  }

  DocumentTranslateCubit cubitOf(WidgetTester tester) =>
      tester.element(find.byType(DocumentTranslateView)).read();

  Future<void> startTranslating(WidgetTester tester) async {
    unawaited(cubitOf(tester).translate());
    await tester.pump();
    await tester.pump();
    expect(cubitOf(tester).state.isTranslating, isTrue);
  }

  Future<void> back(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await settle(tester);
  }

  group('leaving the document screen', () {
    testWidgets('goes back at once when nothing is being translated', (
      tester,
    ) async {
      share.value = (id: 's1', file: file('a.txt', 'Hello'), unavailable: null);
      await pumpHome(tester);
      expect(cubitOf(tester).state.fileName, 'a.txt');
      await back(tester);
      expect(find.byType(DocumentTranslateView), findsNothing);
      expect(find.byKey(const Key('documents_stop_dialog')), findsNothing);
    });

    testWidgets('asks while translating; Cancel stays and goes on', (
      tester,
    ) async {
      share.value = (id: 's1', file: file('a.txt', 'Hello'), unavailable: null);
      await pumpHome(tester);
      await startTranslating(tester);

      await back(tester);
      expect(find.byKey(const Key('documents_stop_dialog')), findsOneWidget);
      expect(find.text('Stop translating and leave?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('documents_stop_cancel')));
      await settle(tester);
      expect(find.byType(DocumentTranslateView), findsOneWidget);
      expect(cubitOf(tester).state.isTranslating, isTrue);
    });

    testWidgets('asks while translating; Stop and leave stops and leaves', (
      tester,
    ) async {
      share.value = (id: 's1', file: file('a.txt', 'Hello'), unavailable: null);
      await pumpHome(tester);
      await startTranslating(tester);
      final cubit = cubitOf(tester);

      await tester.tap(find.byType(BackButton));
      await settle(tester);
      await tester.tap(find.byKey(const Key('documents_stop_confirm')));
      await settle(tester);
      expect(find.byType(DocumentTranslateView), findsNothing);
      expect(cubit.isClosed, isTrue);
    });

    testWidgets('the first screen of the app leaves the app', (tester) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      setSurface(tester, const Size(600, 3000));
      await tester.pumpDocuments(
        translateCubit: translateCubit,
        repository: repository,
        files: files,
        initialFile: file('a.txt', 'Hello'),
      );
      await startTranslating(tester);
      await back(tester);
      await tester.tap(find.byKey(const Key('documents_stop_confirm')));
      await settle(tester);
      expect(calls.map((c) => c.method), contains('SystemNavigator.pop'));
      expect(cubitOf(tester).state.isTranslating, isFalse);
    });
  });

  group('a new shared file', () {
    testWidgets('replaces the document right away when idle', (tester) async {
      share.value = (id: 's1', file: file('a.txt', 'Hello'), unavailable: null);
      await pumpHome(tester);
      final cubit = cubitOf(tester);

      share.value = (id: 's2', file: file('b.srt', srt), unavailable: null);
      await settle(tester);
      expect(cubitOf(tester), same(cubit));
      expect(cubit.state.fileName, 'b.srt');

      // The same share again (a rebuild) changes nothing.
      cubit.clear();
      share.value = (id: 's2', file: file('b.srt', srt), unavailable: null);
      await settle(tester);
      expect(cubit.state.fileName, isNull);

      share.value = (
        id: 's3',
        file: null,
        unavailable: (name: 'c.pdf', tooLarge: true),
      );
      await settle(tester);
      expect(cubit.state.error, DocumentError.tooLarge);
      expect(cubit.state.fileName, 'c.pdf');
    });

    testWidgets('asks first while translating; Cancel keeps the work', (
      tester,
    ) async {
      share.value = (id: 's1', file: file('a.txt', 'Hello'), unavailable: null);
      await pumpHome(tester);
      await startTranslating(tester);

      share.value = (id: 's2', file: file('b.srt', srt), unavailable: null);
      await settle(tester);
      expect(
        find.text('Stop translating and open the shared file?'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('documents_stop_cancel')));
      await settle(tester);
      expect(cubitOf(tester).state.fileName, 'a.txt');
      expect(cubitOf(tester).state.isTranslating, isTrue);
    });

    testWidgets('asks first while translating; Stop and open opens it', (
      tester,
    ) async {
      share.value = (id: 's1', file: file('a.txt', 'Hello'), unavailable: null);
      await pumpHome(tester);
      await startTranslating(tester);

      share.value = (id: 's2', file: null, unavailable: null);
      await settle(tester);
      await tester.tap(find.byKey(const Key('documents_stop_confirm')));
      await settle(tester);
      final state = cubitOf(tester).state;
      expect(state.isTranslating, isFalse);
      // A share without a file could not be read.
      expect(state.error, DocumentError.readFailed);
    });
  });
}

const srt = '1\n00:00:01,000 --> 00:00:02,000\nHola\n';
