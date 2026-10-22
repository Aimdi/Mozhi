import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/widgets/delete_local_data.dart';
import 'package:mozhi/sync/data/sync_service.dart';

import '../../../sync/helpers/sync_harness.dart';
import '../helpers.dart';

class _MockSyncService extends Mock implements SyncService;

void main() {
  setUpAll(() {
    registerFallbacks();
    registerFallbackValue(const AppSettings());
  });

  late MockHistoryCubit history;
  late MockSettingsCubit settings;

  setUp(() {
    history = createHistoryCubit();
    when(() => history.search(any())).thenReturn(null);
    settings = createSettingsCubit();
  });

  test('forgets sync first, without touching the server', () async {
    final harness = SyncHarness();
    await harness.setUp();
    final calls = <String>[];
    when(history.deleteAll).thenAnswer((_) async {
      // Sync is already off when the history goes.
      calls.add('history: set up ${harness.service.state.isSetUp}');
    });
    harness.server.requests.clear();
    await LocalDataEraser(
      history: history,
      settings: settings,
      sync: harness.service,
    ).erase();
    expect(calls, ['history: set up false']);
    expect(harness.secrets.values, isEmpty);
    expect(harness.prefs.values, isEmpty);
    expect(harness.server.requests, isEmpty);
    expect(harness.server.files, contains(syncFilePath));
  });

  test('a failure to forget is reported after the rest', () async {
    final sync = _MockSyncService();
    when(sync.forget).thenThrow(StateError('keystore'));
    when(history.deleteAll).thenAnswer((_) async {});
    await expectLater(
      LocalDataEraser(history: history, settings: settings, sync: sync).erase(),
      throwsStateError,
    );
    verify(history.deleteAll).called(1);
  });

  testWidgets('of reads the sync service', (tester) async {
    final sync = _MockSyncService();
    late LocalDataEraser found;
    await tester.pumpWidget(
      RepositoryProvider<SyncService>.value(
        value: sync,
        child: MultiBlocProvider(
          providers: [
            BlocProvider<HistoryCubit>.value(value: history),
            BlocProvider<SettingsCubit>.value(value: settings),
          ],
          child: Builder(
            builder: (context) {
              found = LocalDataEraser.of(context);
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    expect(found.sync, same(sync));
  });
}
