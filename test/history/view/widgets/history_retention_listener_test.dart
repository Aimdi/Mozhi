import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/view/widgets/history_retention_listener.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';

import '../../../settings/view/helpers.dart';

void main() {
  group(HistoryRetentionListener, () {
    late MockSettingsCubit settings;
    late MockHistoryCubit history;
    late StreamController<AppSettings> changes;

    setUp(() {
      changes = StreamController<AppSettings>();
      addTearDown(changes.close);
      settings = createSettingsCubit(
        const AppSettings(historyRetention: HistoryRetention.week),
      );
      whenListen(
        settings,
        changes.stream,
        initialState: const AppSettings(
          historyRetention: HistoryRetention.week,
        ),
      );
      history = createHistoryCubit();
      when(() => history.applyRetention(any())).thenAnswer((_) async {});
    });

    Future<void> pump(WidgetTester tester) => tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<SettingsCubit>.value(value: settings),
          BlocProvider<HistoryCubit>.value(value: history),
        ],
        child: const HistoryRetentionListener(child: SizedBox()),
      ),
    );

    setUpAll(() => registerFallbackValue(Duration.zero));

    testWidgets('applies the current retention when inserted', (tester) async {
      await pump(tester);
      verify(() => history.applyRetention(const Duration(days: 7))).called(1);
    });

    testWidgets('applies every change of the retention', (tester) async {
      await pump(tester);
      clearInteractions(history);

      changes.add(const AppSettings(historyRetention: HistoryRetention.day));
      await tester.pump();
      verify(() => history.applyRetention(const Duration(days: 1))).called(1);

      changes.add(const AppSettings());
      await tester.pump();
      verify(() => history.applyRetention(null)).called(1);
    });

    testWidgets('ignores other setting changes', (tester) async {
      await pump(tester);
      clearInteractions(history);

      changes.add(
        const AppSettings(
          historyRetention: HistoryRetention.week,
          saveHistory: false,
        ),
      );
      await tester.pump();
      verifyNever(() => history.applyRetention(any()));
    });

    testWidgets('builds its child', (tester) async {
      await pump(tester);
      expect(find.byType(SizedBox), findsOneWidget);
    });

    test('historyRetentionChanged compares only the retention', () {
      const settings = AppSettings();
      expect(historyRetentionChanged(settings, settings), isFalse);
      expect(
        historyRetentionChanged(
          settings,
          settings.copyWith(historyRetention: HistoryRetention.month),
        ),
        isTrue,
      );
      expect(
        historyRetentionChanged(
          settings,
          settings.copyWith(saveHistory: false),
        ),
        isFalse,
      );
    });
  });
}
