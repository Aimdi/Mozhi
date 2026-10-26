import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/documents/documents.dart';
import 'package:mozhi/documents/widgets/document_progress_section.dart';

import '../../helpers/helpers.dart';

class _MockDocumentTranslateCubit extends MockCubit<DocumentTranslateState>
    implements DocumentTranslateCubit;

void main() {
  group('DocumentProgressSection', () {
    Future<void> pump(WidgetTester tester, DocumentTranslateState state) {
      final cubit = _MockDocumentTranslateCubit();
      when(() => cubit.state).thenReturn(state);
      return tester.pumpApp(
        Scaffold(
          body: BlocProvider<DocumentTranslateCubit>.value(
            value: cubit,
            child: const DocumentProgressSection(),
          ),
        ),
      );
    }

    const translated = DocumentTranslateState(
      status: DocumentStatus.translated,
    );

    testWidgets('says what the personal data shield kept on the device', (
      tester,
    ) async {
      await pump(tester, translated.copyWith(maskedPersonalData: 2));
      expect(
        find.descendant(
          of: find.byKey(const Key('documents_personal_data_kept')),
          matching: find.text('2 items kept on this device'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('documents_pending')), findsOneWidget);
    });

    testWidgets('shows no note when nothing was kept', (tester) async {
      await pump(tester, translated);
      expect(
        find.byKey(const Key('documents_personal_data_kept')),
        findsNothing,
      );
      expect(find.textContaining('kept on this device'), findsNothing);
    });
  });
}
