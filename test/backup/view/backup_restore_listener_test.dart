import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/backup/view/backup_restore_listener.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/presets/cubit/glossary_cubit.dart';
import 'package:mozhi/presets/cubit/presets_cubit.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';

import '../helpers/backup_fakes.dart';

class _MockSettingsCubit extends MockCubit<AppSettings>
    implements SettingsCubit;

class _MockHistoryCubit extends MockCubit<HistoryState> implements HistoryCubit;

class _MockPresetsCubit extends MockCubit<PresetsState> implements PresetsCubit;

class _MockGlossaryCubit extends MockCubit<GlossaryState>
    implements GlossaryCubit;

void main() {
  late BackupRegistry registry;
  late _MockSettingsCubit settings;
  late _MockHistoryCubit history;
  late _MockPresetsCubit presets;
  late _MockGlossaryCubit glossaries;

  BackupSnapshot snapshotOf(List<String> ids) => BackupSnapshot(
    createdAt: DateTime.utc(2026),
    appVersion: '1',
    sections: {
      for (final id in ids) id: const BackupSectionData(version: 1, data: null),
    },
  );

  setUp(() {
    registry = BackupRegistry();
    for (final id in [
      'settings',
      'history',
      'presets',
      'glossaries',
      'other',
    ]) {
      registry.register(MemorySection(id));
    }
    settings = _MockSettingsCubit();
    history = _MockHistoryCubit();
    presets = _MockPresetsCubit();
    glossaries = _MockGlossaryCubit();
    when(settings.load).thenAnswer((_) async {});
    when(history.load).thenAnswer((_) async {});
    when(presets.load).thenAnswer((_) async {});
    when(glossaries.load).thenAnswer((_) async {});
  });

  Future<void> pump(WidgetTester tester, {bool withRegistry = true}) {
    const child = BackupRestoreListener(child: Text('child'));
    return tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MultiBlocProvider(
          providers: [
            BlocProvider<SettingsCubit>.value(value: settings),
            BlocProvider<HistoryCubit>.value(value: history),
            BlocProvider<PresetsCubit>.value(value: presets),
            BlocProvider<GlossaryCubit>.value(value: glossaries),
          ],
          child: withRegistry
              ? RepositoryProvider.value(value: registry, child: child)
              : child,
        ),
      ),
    );
  }

  testWidgets('reloads the cubits of the restored sections', (tester) async {
    await pump(tester);
    expect(find.text('child'), findsOneWidget);

    await tester.runAsync(
      () => registry.restore(
        snapshotOf(['history', 'presets', 'other']),
        mode: BackupRestoreMode.merge,
      ),
    );
    await tester.pump();

    verify(history.load).called(1);
    verify(presets.load).called(1);
    verifyNever(settings.load);
    verifyNever(glossaries.load);

    await tester.runAsync(
      () => registry.restore(
        snapshotOf(['settings', 'glossaries']),
        mode: BackupRestoreMode.replace,
      ),
    );
    await tester.pump();

    verify(settings.load).called(1);
    verify(glossaries.load).called(1);
  });

  testWidgets('stops listening when removed', (tester) async {
    await pump(tester);
    await tester.pumpWidget(const SizedBox.shrink());

    await tester.runAsync(
      () => registry.restore(
        snapshotOf(['history']),
        mode: BackupRestoreMode.merge,
      ),
    );
    await tester.pump();

    verifyNever(history.load);
  });

  testWidgets('does nothing without a registry', (tester) async {
    await pump(tester, withRegistry: false);

    expect(find.text('child'), findsOneWidget);
  });

  testWidgets('skips cubits that are not provided', (tester) async {
    await tester.pumpWidget(
      RepositoryProvider.value(
        value: registry,
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: BackupRestoreListener(child: Text('child')),
        ),
      ),
    );

    await tester.runAsync(
      () => registry.restore(
        snapshotOf(['settings', 'history', 'presets', 'glossaries']),
        mode: BackupRestoreMode.merge,
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
