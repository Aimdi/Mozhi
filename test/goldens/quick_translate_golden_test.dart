@Tags(['golden', 'skip_very_good_optimization'])
library;

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/quick_translate/quick_translate.dart';

import '../quick_translate/helpers/helpers.dart';
import 'helpers/golden_helpers.dart';

/// Opens the quick translate sheet (as `showQuickTranslate` does on
/// phones) over an empty page, with a finished translation, Open in app
/// and Replace, in the app's theme.
Future<void> _pumpQuickTranslate(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
}) async {
  useGoldenDevice(tester, GoldenDevice.phone);
  final cubit = MockQuickTranslateCubit();
  whenListen(
    cubit,
    const Stream<QuickTranslateState>.empty(),
    initialState: readyState(
      text: 'The museum is open every day except Monday.',
      translation: result('Le musée est ouvert tous les jours sauf le lundi.'),
    ),
  );
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      debugShowCheckedModeBanner: false,
      theme: goldenTheme(brightness),
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(),
    ),
  );
  showModalBottomSheet<void>(
    context: navigator.currentContext!,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => BlocProvider<QuickTranslateCubit>.value(
      value: cubit,
      child: QuickTranslateView(
        canReplace: true,
        onReplace: (_) {},
        onOpenInApp: () {},
        onClose: () {},
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  goldenGroup('Quick translate sheet', () {
    testWidgets('with a translation on a phone (light)', (tester) async {
      await _pumpQuickTranslate(tester);
      await expectScreenGolden('quick_translate_sheet_phone_light');
    });
  });
}
