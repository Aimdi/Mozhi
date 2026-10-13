import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/history/view/history_page.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';

import '../../settings/view/helpers.dart';

void main() {
  setUpAll(registerFallbacks);
  testWidgets('debug', (tester) async {
    final history = createHistoryCubit();
    when(() => history.search(any())).thenReturn(null);
    final translate = MockTranslateCubit();
    when(() => translate.state).thenReturn(const TranslateState());
    final handle = tester.ensureSemantics();
    tester.setScreenSize(const Size(800, 1600));
    await tester.pumpView(const HistoryPage(), history: history, translate: translate);
    debugPrint('NODE0: ${tester.getSemantics(find.byType(EditableText))}');
    await tester.enterText(find.byType(SearchBar), 'morning');
    await tester.pump();
    debugPrint('NODE: ${tester.getSemantics(find.byType(EditableText))}');
    debugPrint('PARENT: ${tester.getSemantics(find.byType(EditableText)).parent}');
    handle.dispose();
  });
}
