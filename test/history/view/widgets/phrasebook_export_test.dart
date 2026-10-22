import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/documents/data/document_file_service.dart';
import 'package:mozhi/history/data/phrasebook_csv.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/history/view/widgets/phrasebook_export.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../../helpers/helpers.dart';

class _FakeFiles implements DocumentFileService {
  bool canShare = true;
  bool saveResult = true;
  Exception? error;
  final saved = <(String, Uint8List, String)>[];
  final shared = <(String, Uint8List, String, Rect?)>[];

  @override
  bool get canShareFiles => canShare;

  @override
  Future<bool> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
  }) async {
    if (error case final error?) throw error;
    saved.add((fileName, bytes, mimeType));
    return saveResult;
  }

  @override
  Future<void> shareFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    Rect? origin,
  }) async {
    if (error case final error?) throw error;
    shared.add((fileName, bytes, mimeType, origin));
  }

  @override
  Future<void> copyText(String text) => throw UnimplementedError();

  @override
  Future<String?> pasteText() => throw UnimplementedError();

  @override
  Future<PickedFile?> pickFile({required List<String> extensions}) =>
      throw UnimplementedError();
}

final _entries = [
  HistoryEntry(
    id: '1',
    text: 'Good morning',
    translation: 'Guten Morgen',
    source: const Language(code: 'en', name: 'English'),
    target: const Language(code: 'de', name: 'German'),
    engineId: 'mozhi:google',
    engineName: 'Google',
    createdAt: DateTime(2026, 10, 22),
    isFavorite: true,
  ),
  HistoryEntry(
    id: '2',
    text: 'Thank you',
    translation: 'Danke',
    source: const Language(code: 'en', name: 'English'),
    target: const Language(code: 'de', name: 'German'),
    engineId: 'mozhi:google',
    engineName: 'Google',
    createdAt: DateTime(2026, 10, 21),
    isFavorite: true,
  ),
];

void main() {
  group('showPhrasebookExport', () {
    late _FakeFiles files;
    late DocumentFileService previous;

    setUp(() {
      previous = PhrasebookExport.files;
      files = _FakeFiles();
      PhrasebookExport.files = files;
    });

    tearDown(() => PhrasebookExport.files = previous);

    Future<void> open(WidgetTester tester) async {
      await tester.pumpApp(
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showPhrasebookExport(context, _entries),
              child: const Text('Export'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Export'));
      await tester.pumpAndSettle();
    }

    testWidgets('says what the file holds and that it is not encrypted', (
      tester,
    ) async {
      await open(tester);
      expect(find.text('Export 2 favorites'), findsOneWidget);
      expect(find.textContaining('Anki'), findsOneWidget);
      expect(find.textContaining("isn't encrypted"), findsOneWidget);
      expect(find.text('Save as CSV'), findsOneWidget);
      expect(find.text('Share CSV'), findsOneWidget);
    });

    testWidgets('saves the CSV file', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const Key('history_export_save')));
      await tester.pumpAndSettle();
      final (name, bytes, type) = files.saved.single;
      expect(name, 'mozhi-favorites.csv');
      expect(type, 'text/csv');
      expect(utf8.decode(bytes), contains('Good morning,Guten Morgen'));
      expect(bytes, PhrasebookCsv.bytes(_entries));
      expect(find.text('Saved 2 favorites'), findsOneWidget);
    });

    testWidgets('says nothing when the save is cancelled', (tester) async {
      files.saveResult = false;
      await open(tester);
      await tester.tap(find.byKey(const Key('history_export_save')));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('shares the CSV file', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const Key('history_export_share')));
      await tester.pumpAndSettle();
      final (name, _, type, origin) = files.shared.single;
      expect(name, 'mozhi-favorites.csv');
      expect(type, 'text/csv');
      expect(origin, isNotNull);
    });

    testWidgets('offers no sharing where files cannot be shared', (
      tester,
    ) async {
      files.canShare = false;
      await open(tester);
      expect(find.text('Share CSV'), findsNothing);
    });

    testWidgets('says when sharing is unsupported', (tester) async {
      files.error = const ShareUnsupportedException();
      await open(tester);
      await tester.tap(find.byKey(const Key('history_export_share')));
      await tester.pumpAndSettle();
      expect(
        find.text(
          "Sharing files isn't supported on this device. Use Save instead.",
        ),
        findsOneWidget,
      );
    });

    testWidgets('says when the export failed', (tester) async {
      files.error = Exception('disk');
      await open(tester);
      await tester.tap(find.byKey(const Key('history_export_save')));
      await tester.pumpAndSettle();
      expect(find.text("Couldn't export your favorites"), findsOneWidget);
    });

    testWidgets('does nothing when dismissed', (tester) async {
      await open(tester);
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();
      expect(files.saved, isEmpty);
      expect(files.shared, isEmpty);
    });
  });
}
