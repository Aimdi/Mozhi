import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/settings/view/widgets/history_data_actions.dart';

import '../../../helpers/helpers.dart';
import '../helpers.dart';

void main() {
  setUpAll(registerFallbacks);

  testWidgets('the history export points to the encrypted backup', (
    tester,
  ) async {
    final history = createHistoryCubit();
    final router = createRouter();
    when(() => router.push<void>(any(), extra: any(named: 'extra')))
        .thenAnswer((_) async {});
    await tester.pumpApp(
      InheritedGoRouter(
        goRouter: router,
        child: BlocProvider<HistoryCubit>.value(
          value: history,
          child: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showExportHistorySheet(context),
                child: const Text('export'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('export'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Make an encrypted backup instead'));
    await tester.pumpAndSettle();

    verify(() => router.push<void>('/settings/backup?row=backup_now'))
        .called(1);
    verifyNever(history.exportJson);
  });
}
