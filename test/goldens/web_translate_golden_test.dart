@Tags(['golden', 'skip_very_good_optimization'])
library;

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/web_translate/web_translate.dart';
import 'package:translation_repository/translation_repository.dart';

import '../web_translate/helpers/helpers.dart';
import 'helpers/golden_helpers.dart';

/// Pumps [WebTranslatePage] before an address is entered, on a phone with
/// the translate screen's engine and languages and the app's theme.
Future<void> _pumpWebTranslate(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
}) async {
  useGoldenDevice(tester, GoldenDevice.phone);
  final translate = MockTranslateCubit();
  whenListen(
    translate,
    const Stream<TranslateState>.empty(),
    initialState: translateState(),
  );
  await tester.pumpWidget(
    RepositoryProvider<TranslationRepository>.value(
      value: FakeTranslationRepository(),
      child: BlocProvider<TranslateCubit>.value(
        value: translate,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: goldenTheme(brightness),
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: WebTranslatePage(
            fetcher: WebPageFetcher(
              isWeb: false,
              client: htmlClient(samplePageHtml),
            ),
            extract: (page) async => extractFetchedPage(page),
            isWeb: false,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  goldenGroup('Web page translation screen', () {
    testWidgets('empty on a phone (light)', (tester) async {
      await _pumpWebTranslate(tester);
      await expectScreenGolden('web_translate_empty_phone_light');
    });
  });
}
