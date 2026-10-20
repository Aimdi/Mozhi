@Tags(['golden', 'skip_very_good_optimization'])
library;

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/documents/documents.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import '../documents/helpers/fakes.dart';
import 'helpers/golden_helpers.dart';

/// Pumps [DocumentTranslatePage] on a phone with the translate screen's
/// engines and languages and the app's theme.
Future<void> _pumpDocuments(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
}) async {
  useGoldenDevice(tester, GoldenDevice.phone);
  final translate = MockTranslateCubit();
  whenListen(
    translate,
    const Stream<TranslateState>.empty(),
    initialState: readyTranslateState,
  );
  final repository = MockTranslationRepository();
  stubLanguages(repository);
  await tester.pumpWidget(
    RepositoryProvider<TranslationRepository>.value(
      value: repository,
      child: BlocProvider<TranslateCubit>.value(
        value: translate,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: goldenTheme(brightness),
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DocumentTranslatePage(fileService: FakeDocumentFileService()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(registerDocumentFallbacks);

  goldenGroup('Documents screen', () {
    testWidgets('empty on a phone (light)', (tester) async {
      await _pumpDocuments(tester);
      await expectScreenGolden('documents_empty_phone_light');
    });
  });
}
