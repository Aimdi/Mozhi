import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/documents/data/document_file_service.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/data/history_repository.dart';
import 'package:mozhi/settings/view/widgets/history_data_actions.dart';

import '../../../helpers/helpers.dart';
import '../helpers.dart';

class _MockFiles extends Mock implements DocumentFileService;

void main() {
  setUpAll(registerFallbacks);

  late _MockFiles files;
  late HistoryCubit history;

  setUp(() {
    files = _MockFiles();
    HistoryShare.files = files;
    addTearDown(() => HistoryShare.files = const PlatformDocumentFileService());
    history = createHistoryCubit();
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpApp(
      BlocProvider<HistoryCubit>.value(
        value: history,
        child: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showImportHistoryDialog(context),
              child: const Text('import'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('import'));
    await tester.pumpAndSettle();
  }

  void pick(PickedFile? file) =>
      when(() => files.pickFile(extensions: any(named: 'extensions')))
          .thenAnswer((_) async => file);

  testWidgets('imports the chosen exported file', (tester) async {
    const json = '{"version":1,"entries":[]}';
    pick(
      PickedFile(
        name: HistoryShare.fileName,
        bytes: Uint8List.fromList(utf8.encode(json)),
      ),
    );
    when(() => history.importJson(json)).thenAnswer(
      (_) async => const HistoryImport(entries: [], added: 0, expired: 0),
    );
    await open(tester);
    expect(find.text('Choose file'), findsOneWidget);
    await tester.tap(find.byKey(const Key('history_import_choose_file')));
    await tester.pumpAndSettle();
    verify(() => files.pickFile(extensions: const ['json'])).called(1);
    verify(() => history.importJson(json)).called(1);
    expect(find.byType(ImportHistoryDialog), findsNothing);
    expect(find.text('History imported'), findsOneWidget);
  });

  testWidgets('a cancelled pick changes nothing', (tester) async {
    pick(null);
    await open(tester);
    await tester.tap(find.byKey(const Key('history_import_choose_file')));
    await tester.pumpAndSettle();
    expect(find.byType(ImportHistoryDialog), findsOneWidget);
    verifyNever(() => history.importJson(any()));
  });

  testWidgets('a file that is not text or not history is refused', (
    tester,
  ) async {
    pick(PickedFile(name: 'x.json', bytes: Uint8List.fromList([0xff, 0xfe])));
    await open(tester);
    await tester.tap(find.byKey(const Key('history_import_choose_file')));
    await tester.pumpAndSettle();
    expect(find.text("This isn't valid Mozhi history JSON."), findsOneWidget);

    pick(PickedFile(name: 'x.json', bytes: Uint8List.fromList([0x7b])));
    when(() => history.importJson('{')).thenThrow(const FormatException());
    await tester.tap(find.byKey(const Key('history_import_choose_file')));
    await tester.pumpAndSettle();
    expect(find.text("This isn't valid Mozhi history JSON."), findsOneWidget);
    expect(find.byType(ImportHistoryDialog), findsOneWidget);

    when(() => files.pickFile(extensions: any(named: 'extensions')))
        .thenThrow(const DocumentFileTooLargeException('big.json'));
    await tester.tap(find.byKey(const Key('history_import_choose_file')));
    await tester.pumpAndSettle();
    expect(find.text("This isn't valid Mozhi history JSON."), findsOneWidget);
  });
}
