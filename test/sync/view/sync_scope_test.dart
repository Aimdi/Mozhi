import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/data/settings_repository.dart';
import 'package:mozhi/sync/data/sync_service.dart';
import 'package:mozhi/sync/view/sync_scope.dart';

class _MockSyncService extends Mock implements SyncService;

void main() {
  late _MockSyncService service;

  setUp(() {
    service = _MockSyncService();
    when(service.start).thenAnswer((_) async {});
    when(service.flush).thenAnswer((_) async {});
  });

  testWidgets('wrap leaves the child alone without a service', (tester) async {
    const child = SizedBox(key: Key('child'));
    expect(SyncScope.wrap(service: null, child: child), same(child));
    expect(SyncScope.wrap(service: service, child: child), isA<SyncScope>());
  });

  testWidgets('starts after the first frame, notifies changes and flushes '
      'in the background', (tester) async {
    final settings = SettingsCubit(
      repository: SettingsRepository(
        prefs: MemoryStore(),
        secrets: MemoryStore(),
      ),
    );
    final extra = StreamController<Object?>.broadcast();
    await tester.pumpWidget(
      BlocProvider<SettingsCubit>.value(
        value: settings,
        child: SyncScope(
          service: service,
          changes: [extra.stream],
          child: const SizedBox(),
        ),
      ),
    );
    verify(service.start).called(1);

    settings.setMultilineInput(enabled: !settings.state.multilineInput);
    extra.add(null);
    await tester.pump();
    verify(service.notifyChanged).called(2);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    verifyNever(service.flush);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    verify(service.flush).called(2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    await tester.pumpWidget(const SizedBox());
    extra.add(null);
    await tester.pump();
    verifyNever(service.notifyChanged);
    await extra.close();
    await settings.close();
  });
}
