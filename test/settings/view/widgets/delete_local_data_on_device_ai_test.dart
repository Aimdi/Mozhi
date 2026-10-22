import 'dart:io';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llama_engine/llama_engine.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/on_device_ai/data/on_device_models.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/widgets/delete_local_data.dart';

import '../helpers.dart';

class _MockOnDeviceModels extends Mock implements OnDeviceModels;

class _MockManager extends Mock implements LlamaModelManager;

const int _gib = 1024 * 1024 * 1024;

void main() {
  setUpAll(() {
    registerFallbacks();
    registerFallbackValue(const AppSettings());
  });

  late MockHistoryCubit history;
  late MockSettingsCubit settings;
  late _MockOnDeviceModels models;
  late _MockManager manager;

  setUp(() {
    history = createHistoryCubit();
    when(history.deleteAll).thenAnswer((_) async {});
    when(() => history.search(any())).thenReturn(null);
    settings = createSettingsCubit();
    models = _MockOnDeviceModels();
    manager = _MockManager();
    when(() => models.manager).thenReturn(manager);
    when(models.deleteAll).thenAnswer((_) async {});
    when(manager.installed).thenAnswer(
      (_) async => const [
        InstalledLlamaModel(
          id: 'hy',
          path: '/models/hy/hy.gguf',
          sizeBytes: _gib,
          sha256: 'a',
        ),
        InstalledLlamaModel(
          id: 'qwen',
          path: '/models/qwen/qwen.gguf',
          sizeBytes: _gib ~/ 2,
          sha256: 'b',
        ),
      ],
    );
  });

  LocalDataEraser eraser() => LocalDataEraser(
    history: history,
    settings: settings,
    onDeviceModels: models,
  );

  test('counts the on-device AI models and their size', () async {
    final summary = await eraser().summarize();
    expect(summary.onDeviceModels, 2);
    expect(summary.onDeviceModelBytes, _gib + _gib ~/ 2);
  });

  test('counts nothing when the folder cannot be read', () async {
    when(manager.installed).thenThrow(const FileSystemException('x'));
    final summary = await eraser().summarize();
    expect(summary.onDeviceModels, 0);
    expect(summary.onDeviceModelBytes, 0);
    final without = await LocalDataEraser(
      history: history,
      settings: settings,
    ).summarize();
    expect(without.onDeviceModels, 0);
  });

  test('deletes the models and the choices', () async {
    await eraser().erase();
    verify(models.deleteAll).called(1);
  });

  test('reports a failed deletion after trying the rest', () async {
    when(models.deleteAll).thenThrow(StateError('busy'));
    await expectLater(eraser().erase(), throwsStateError);
    verify(() => settings.update(any())).called(1);
  });

  testWidgets('of reads the on-device models', (tester) async {
    late LocalDataEraser found;
    await tester.pumpWidget(
      RepositoryProvider<OnDeviceModels>.value(
        value: models,
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
    expect(found.onDeviceModels, same(models));
  });

  testWidgets('the confirmation lists the models with their size', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: DeleteLocalDataDialog(
            summary: LocalDataSummary(
              historyEntries: 0,
              apiKeys: 0,
              onDeviceModels: 2,
              onDeviceModelBytes: _gib + _gib ~/ 2,
            ),
          ),
        ),
      ),
    );
    expect(find.text('2 on-device AI models (1.5 GB)'), findsOneWidget);
  });

  testWidgets('the confirmation leaves them out without models', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: DeleteLocalDataDialog(
            summary: LocalDataSummary(historyEntries: 0, apiKeys: 0),
          ),
        ),
      ),
    );
    expect(find.textContaining('on-device AI'), findsNothing);
  });
}
