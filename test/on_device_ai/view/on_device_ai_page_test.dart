import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llama_engine/llama_engine.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/on_device_ai/cubit/on_device_ai_settings_cubit.dart';
import 'package:mozhi/on_device_ai/data/on_device_models.dart';
import 'package:mozhi/on_device_ai/view/model_size.dart';
import 'package:mozhi/on_device_ai/view/on_device_ai_page.dart';
import 'package:mozhi/platform/free_space.dart';
import 'package:mozhi/settings/view/widgets/link_launcher.dart';

import '../../helpers/helpers.dart';
import '../helpers.dart';

class _MockCubit extends MockCubit<OnDeviceAiSettingsState>
    implements OnDeviceAiSettingsCubit;

class _MockModels extends Mock implements OnDeviceModels;

const int _gib = 1024 * 1024 * 1024;

void main() {
  late AppLocalizations l10n;
  late _MockCubit cubit;
  final hy = LlamaCatalogModel(
    id: 'hy',
    name: 'hy.gguf',
    url: Uri.parse('https://models.example/hy.gguf'),
    size: (1.1 * _gib).round(),
    sha256: 'a' * 64,
    role: LlamaModelRole.translation,
    family: 'hunyuan-dense',
    promptProfile: 'hunyuanMt',
    displayName: 'Hy-MT2 1.8B',
    parameters: '1.8B',
    quantization: 'Q4_K_M',
    minRamMb: 5000,
    recommendedRamMb: 7000,
    languages: const ['zh-CN', 'en', 'de'],
    license: 'Apache-2.0',
    licenseUrl: Uri.parse('https://example.org/LICENSE'),
    sourceUrl: Uri.parse('https://example.org/hy'),
  );
  final gemma = fakeOnDeviceModel(
    'gemma',
    ggufBytes(10),
    displayName: 'Gemma 4 E2B',
  );
  final qwen = fakeOnDeviceModel('qwen', ggufBytes(12), displayName: 'Qwen3');

  OnDeviceModel entry(
    LlamaCatalogModel model, {
    bool installed = false,
    OnDeviceFit fit = OnDeviceFit.ok,
    int partialBytes = 0,
  }) => OnDeviceModel(
    model: model,
    fit: fit,
    installed: installed,
    partialBytes: partialBytes,
  );

  OnDeviceAiSettingsState ready({
    List<OnDeviceModel>? models,
    String? translationModel,
    String? assistantModel,
    Map<String, OnDeviceModelOperation> pending = const {},
    Map<String, double> progress = const {},
    bool importing = false,
  }) => OnDeviceAiSettingsState(
    status: OnDeviceAiSettingsStatus.ready,
    supported: true,
    models:
        models ??
        [
          entry(hy, installed: true),
          entry(gemma, fit: OnDeviceFit.slow),
          entry(qwen),
        ],
    translationModel: translationModel,
    assistantModel: assistantModel,
    pending: pending,
    progress: progress,
    importing: importing,
  );

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  setUp(() {
    cubit = _MockCubit();
    when(() => cubit.state).thenReturn(ready());
    when(() => cubit.isClosed).thenReturn(false);
    when(
      () => cubit.download(
        any(),
        overMeteredNetwork: any(named: 'overMeteredNetwork'),
      ),
    ).thenAnswer((_) async {});
    when(() => cubit.delete(any())).thenAnswer((_) async {});
    when(() => cubit.select(any())).thenAnswer((_) async {});
    when(() => cubit.importFromFiles()).thenAnswer((_) async {});
  });

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    if (finder.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        finder,
        200,
        scrollable: find.byType(Scrollable).first,
      );
    }
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
  }

  Future<void> pumpView(WidgetTester tester) => tester.pumpApp(
    BlocProvider<OnDeviceAiSettingsCubit>.value(
      value: cubit,
      child: const OnDeviceAiView(),
    ),
  );

  group(OnDeviceAiPage, () {
    testWidgets('says the device cannot run it without on-device AI', (
      tester,
    ) async {
      await tester.pumpApp(const OnDeviceAiPage());
      await tester.pumpAndSettle();
      expect(find.text(l10n.onDeviceAiTitle), findsOneWidget);
      expect(find.text(l10n.onDeviceAiIntro), findsOneWidget);
      expect(find.text(l10n.onDeviceAiDeviceUnavailable), findsOneWidget);
    });

    testWidgets('reads the models from context', (tester) async {
      final models = _MockModels();
      when(() => models.ready).thenAnswer((_) async {});
      when(() => models.changes).thenAnswer((_) => const Stream.empty());
      when(models.models).thenAnswer((_) async => [entry(hy)]);
      when(() => models.translationModel).thenReturn(null);
      when(() => models.assistantModel).thenReturn(null);
      when(() => models.downloads).thenReturn(const {});
      await tester.pumpApp(
        RepositoryProvider<OnDeviceModels>.value(
          value: models,
          child: const OnDeviceAiPage(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Hy-MT2 1.8B'), findsOneWidget);
      expect(find.text(l10n.onDeviceAiTranslationSection), findsOneWidget);
      expect(find.text(l10n.onDeviceAiAssistantSection), findsNothing);
    });
  });

  group(OnDeviceAiView, () {
    testWidgets('shows a spinner while loading', (tester) async {
      when(() => cubit.state).thenReturn(const OnDeviceAiSettingsState());
      await pumpView(tester);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('says when the catalogue has no models', (tester) async {
      when(() => cubit.state).thenReturn(ready(models: const []));
      await pumpView(tester);
      expect(find.text(l10n.onDeviceAiNoModels), findsOneWidget);
    });

    testWidgets('lists the models with size, licence, languages and fit', (
      tester,
    ) async {
      when(() => cubit.state).thenReturn(
        ready(
          models: [
            entry(hy, installed: true),
            entry(gemma, fit: OnDeviceFit.slow),
            entry(qwen, fit: OnDeviceFit.tooBig),
          ],
          translationModel: 'hy',
        ),
      );
      await pumpView(tester);
      expect(find.text(l10n.onDeviceAiTranslationSection), findsOneWidget);
      expect(find.text(l10n.onDeviceAiAssistantSection), findsOneWidget);
      expect(find.text('1.1 GB · Apache-2.0 · 3 languages'), findsOneWidget);
      expect(find.text(l10n.onDeviceAiFitOk), findsOneWidget);
      expect(find.text(l10n.onDeviceAiFitSlow), findsOneWidget);
      expect(find.text(l10n.onDeviceAiFitTooBig), findsOneWidget);
      expect(find.text(l10n.onDeviceAiInUse), findsOneWidget);
      // In use: a check; installed: delete; too big: no download.
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(find.byKey(const Key('on_device_ai_delete_hy')), findsOneWidget);
      expect(
        find.byKey(const Key('on_device_ai_download_gemma')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('on_device_ai_download_qwen')), findsNothing);
      expect(
        tester.getSemantics(find.byKey(const Key('on_device_ai_model_hy'))),
        isSemantics(isSelected: true),
      );
    });

    testWidgets('an unknown fit says nothing about memory', (tester) async {
      when(() => cubit.state)
          .thenReturn(ready(models: [entry(qwen, fit: OnDeviceFit.unknown)]));
      await pumpView(tester);
      expect(find.byKey(const Key('on_device_ai_fit_qwen')), findsNothing);
      expect(
        find.byKey(const Key('on_device_ai_download_qwen')),
        findsOneWidget,
      );
    });

    testWidgets('downloads, cancels, selects and deletes', (tester) async {
      when(() => cubit.state).thenReturn(
        ready(
          models: [
            entry(hy, installed: true),
            entry(gemma),
            entry(qwen, installed: true),
          ],
          pending: const {'gemma': OnDeviceModelOperation.download},
          progress: const {'gemma': 0.42},
          assistantModel: 'qwen',
        ),
      );
      await pumpView(tester);
      expect(find.text(l10n.onDeviceAiDownloading(42)), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      await tapVisible(
        tester,
        find.byKey(const Key('on_device_ai_cancel_gemma')),
      );
      verify(() => cubit.cancel('gemma')).called(1);

      // hy is installed and not in use (no translation model chosen).
      await tapVisible(tester, find.text('Hy-MT2 1.8B'));
      verify(() => cubit.select('hy')).called(1);

      await tapVisible(
        tester,
        find.byKey(const Key('on_device_ai_delete_qwen')),
      );
      await tester.pumpAndSettle();
      expect(find.text(l10n.onDeviceAiDeleteTitle('Qwen3')), findsOneWidget);
      await tester.tap(find.text(l10n.commonCancel));
      await tester.pumpAndSettle();
      verifyNever(() => cubit.delete(any()));
      await tapVisible(
        tester,
        find.byKey(const Key('on_device_ai_delete_qwen')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('on_device_ai_delete_confirm')));
      await tester.pumpAndSettle();
      verify(() => cubit.delete('qwen')).called(1);
    });

    testWidgets('a deletion in progress shows a spinner', (tester) async {
      when(() => cubit.state).thenReturn(
        ready(
          models: [entry(qwen, installed: true)],
          pending: const {'qwen': OnDeviceModelOperation.delete},
        ),
      );
      await pumpView(tester);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byKey(const Key('on_device_ai_delete_qwen')), findsNothing);
    });

    testWidgets('starts a download', (tester) async {
      await pumpView(tester);
      await tapVisible(
        tester,
        find.byKey(const Key('on_device_ai_download_qwen')),
      );
      verify(() => cubit.download('qwen')).called(1);
    });

    testWidgets('a paused download can be continued or discarded', (
      tester,
    ) async {
      when(() => cubit.state)
          .thenReturn(ready(models: [entry(qwen, partialBytes: 6)]));
      await pumpView(tester);
      expect(find.text(l10n.onDeviceAiPaused(50)), findsOneWidget);
      await tapVisible(
        tester,
        find.byKey(const Key('on_device_ai_about_qwen')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('on_device_ai_discard')));
      await tester.pumpAndSettle();
      verify(() => cubit.delete('qwen')).called(1);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('the about dialog tells what a model is and opens links', (
      tester,
    ) async {
      final opened = <Uri>[];
      final previous = LinkLauncher.launcher;
      LinkLauncher.launcher = (uri) async {
        opened.add(uri);
        return true;
      };
      addTearDown(() => LinkLauncher.launcher = previous);
      await pumpView(tester);
      await tapVisible(tester, find.byKey(const Key('on_device_ai_about_hy')));
      await tester.pumpAndSettle();
      expect(
        find.text(l10n.onDeviceAiAboutParameters('1.8B', 'Q4_K_M')),
        findsOneWidget,
      );
      expect(find.text(l10n.onDeviceAiAboutSize('1.1 GB')), findsOneWidget);
      expect(
        find.text(l10n.onDeviceAiAboutMemory('4.9 GB', '6.8 GB')),
        findsOneWidget,
      );
      expect(
        find.text('Chinese (Simplified), English, German'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('on_device_ai_discard')), findsNothing);
      await tapVisible(
        tester,
        find.byKey(const Key('on_device_ai_about_license')),
      );
      await tapVisible(
        tester,
        find.byKey(const Key('on_device_ai_about_source')),
      );
      expect(opened, [hy.licenseUrl, hy.sourceUrl]);
      await tester.tap(find.text(l10n.commonClose));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('imports files and copies the links', (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await pumpView(tester);
      await tapVisible(tester, find.byKey(const Key('on_device_ai_import')));
      verify(() => cubit.importFromFiles()).called(1);
      await tapVisible(
        tester,
        find.byKey(const Key('on_device_ai_copy_links')),
      );
      await tester.pumpAndSettle();
      expect(copied, ['${hy.url}\n${gemma.url}\n${qwen.url}']);
      expect(find.text(l10n.commonCopied), findsOneWidget);
    });

    testWidgets('an import in progress cannot start again', (tester) async {
      when(() => cubit.state).thenReturn(ready(importing: true));
      await pumpView(tester);
      final tile = find.byKey(const Key('on_device_ai_import'));
      await tester.scrollUntilVisible(
        tile,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      // The spinner never settles.
      await tester.tap(tile);
      await tester.pump();
      expect(find.text(l10n.offlineImporting), findsOneWidget);
      verifyNever(() => cubit.importFromFiles());
    });

    testWidgets('asks before downloading over mobile data', (tester) async {
      const metered = OnDeviceModelOutcome(
        model: 'qwen',
        operation: OnDeviceModelOperation.download,
        succeeded: false,
        error: OnDeviceModelError(OnDeviceModelErrorKind.metered),
      );
      whenListen(
        cubit,
        Stream.value(ready().copyWith(outcome: () => metered)),
        initialState: ready(),
      );
      await pumpView(tester);
      await tester.pumpAndSettle();
      expect(find.text(l10n.offlineMeteredTitle), findsOneWidget);
      expect(
        find.text(
          l10n.onDeviceAiMeteredBody('Qwen3', formatModelSize(l10n, qwen.size)),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('on_device_ai_metered_confirm')));
      await tester.pumpAndSettle();
      verify(() => cubit.download('qwen', overMeteredNetwork: true)).called(1);
    });

    testWidgets('declining the metered download does nothing', (tester) async {
      const metered = OnDeviceModelOutcome(
        model: 'qwen',
        operation: OnDeviceModelOperation.download,
        succeeded: false,
        error: OnDeviceModelError(OnDeviceModelErrorKind.metered),
      );
      whenListen(
        cubit,
        Stream.value(ready().copyWith(outcome: () => metered)),
        initialState: ready(),
      );
      await pumpView(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.commonCancel));
      await tester.pumpAndSettle();
      verifyNever(
        () => cubit.download(
          any(),
          overMeteredNetwork: any(named: 'overMeteredNetwork'),
        ),
      );
    });

    final messages = <String, (OnDeviceModelOutcome, String)>{
      'done': (
        const OnDeviceModelOutcome(
          model: 'qwen',
          operation: OnDeviceModelOperation.download,
          succeeded: true,
        ),
        'Qwen3 is ready',
      ),
      'deleted': (
        const OnDeviceModelOutcome(
          model: 'qwen',
          operation: OnDeviceModelOperation.delete,
          succeeded: true,
        ),
        'Qwen3 was deleted',
      ),
      'delete failed': (
        const OnDeviceModelOutcome(
          model: 'qwen',
          operation: OnDeviceModelOperation.delete,
          succeeded: false,
        ),
        'Couldn’t delete Qwen3',
      ),
      'cancelled': (
        _failed(OnDeviceModelErrorKind.cancelled),
        'Stopped downloading Qwen3. Download it again to continue.',
      ),
      'too big': (
        _failed(OnDeviceModelErrorKind.tooBig),
        'Qwen3 needs more memory than this phone has.',
      ),
      'checksum': (
        _failed(OnDeviceModelErrorKind.checksum),
        'Qwen3 didn’t download correctly, so it was discarded. Try again.',
      ),
      'checksum from a mirror': (
        _failed(OnDeviceModelErrorKind.checksum, mirror: 'm.example'),
        'Qwen3 didn’t download correctly from m.example, so it was '
            'discarded. The mirror may be out of date.',
      ),
      'server': (
        _failed(OnDeviceModelErrorKind.server, status: 503),
        'Couldn’t download Qwen3: the server answered with error 503.',
      ),
      'server of a mirror': (
        _failed(OnDeviceModelErrorKind.server, status: 404, mirror: 'm.ex'),
        'Couldn’t download Qwen3 from m.ex: it answered with error 404. The '
            'mirror may not have it yet; ask its owner or change the model '
            'source.',
      ),
      'network': (
        _failed(OnDeviceModelErrorKind.network),
        'Couldn’t download Qwen3. Check your connection and try again: the '
            'download continues where it stopped.',
      ),
      'network of a mirror': (
        _failed(OnDeviceModelErrorKind.network, mirror: 'm.ex'),
        'Couldn’t reach m.ex to download Qwen3. Check your connection or the '
            'model source.',
      ),
      'storage': (
        _failed(OnDeviceModelErrorKind.storage),
        'Couldn’t save Qwen3. Free up some storage and try again.',
      ),
      'not enough space': (
        const OnDeviceModelOutcome(
          model: 'qwen',
          operation: OnDeviceModelOperation.download,
          succeeded: false,
          error: OnDeviceModelError(
            OnDeviceModelErrorKind.space,
            space: SpaceShortfall(
              requiredBytes: 1288490189,
              availableBytes: 300 * 1024 * 1024,
            ),
          ),
        ),
        'Not enough free space for Qwen3: needs 1.2 GB, 300 MB free.',
      ),
      'not enough space, unknown how much': (
        _failed(OnDeviceModelErrorKind.space),
        'Couldn’t save Qwen3. Free up some storage and try again.',
      ),
      'unknown': (
        _failed(OnDeviceModelErrorKind.unknown),
        'Couldn’t download Qwen3. Try again.',
      ),
    };
    for (final MapEntry(key: name, value: (outcome, text))
        in messages.entries) {
      testWidgets('says $name', (tester) async {
        whenListen(
          cubit,
          Stream.value(ready().copyWith(outcome: () => outcome)),
          initialState: ready(),
        );
        await pumpView(tester);
        await tester.pump();
        expect(find.text(text), findsOneWidget);
      });
    }

    final imports = <String, (OnDeviceImportOutcome, String)>{
      'failed': (
        const OnDeviceImportOutcome(failed: true),
        'Couldn’t import the files',
      ),
      'nothing': (
        const OnDeviceImportOutcome(unmatchedFiles: 2),
        'None of the files is an on-device model this version of Mozhi knows',
      ),
      'results': (
        const OnDeviceImportOutcome(
          models: {
            'hy': LlamaImportStatus.installed,
            'gemma': LlamaImportStatus.alreadyInstalled,
            'qwen': LlamaImportStatus.checksumMismatch,
            'x': LlamaImportStatus.failed,
          },
        ),
        'Installed Hy-MT2 1.8B\nGemma 4 E2B was already installed\nThe file '
            'for Qwen3 is damaged (checksum mismatch)\nCouldn’t import the '
            'files',
      ),
      'not enough space': (
        const OnDeviceImportOutcome(
          models: {'gemma': LlamaImportStatus.failed},
          space: SpaceShortfall(
            requiredBytes: 3 * 1024 * 1024 * 1024,
            availableBytes: 20 * 1024 * 1024,
          ),
        ),
        'Not enough free space for Gemma 4 E2B: needs 3.0 GB, 20 MB free.',
      ),
      'too big': (
        const OnDeviceImportOutcome(
          models: {'gemma': LlamaImportStatus.installed},
          tooBig: {'gemma'},
        ),
        'Installed Gemma 4 E2B. Gemma 4 E2B needs more memory than this '
            'phone has: it may not run, or be very slow.',
      ),
    };
    for (final MapEntry(key: name, value: (outcome, text)) in imports.entries) {
      testWidgets('reports the import: $name', (tester) async {
        whenListen(
          cubit,
          Stream.value(ready().copyWith(importOutcome: () => outcome)),
          initialState: ready(),
        );
        await pumpView(tester);
        await tester.pump();
        expect(find.text(text), findsOneWidget);
      });
    }

    testWidgets('names the engine build for support', (tester) async {
      when(() => cubit.state).thenReturn(
        ready().copyWith(
          engineBuild: () => const LlamaEngineBuild(
            variant: LlamaCpuVariant.baseline,
            library: 'libmozhi_llama.so',
            skipped: [LlamaCpuVariant.i8mm],
          ),
        ),
      );
      await pumpView(tester);
      await tester.scrollUntilVisible(
        find.byKey(const Key('on_device_ai_engine_build')),
        200,
      );
      expect(find.textContaining('Engine build: baseline'), findsOneWidget);
      expect(find.textContaining('the faster i8mm build'), findsOneWidget);
    });

    testWidgets('lays out in dark mode on a phone', (tester) async {
      tester.view.physicalSize = const Size(360, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpApp(
        BlocProvider<OnDeviceAiSettingsCubit>.value(
          value: cubit,
          child: const OnDeviceAiView(),
        ),
        theme: ThemeData(brightness: Brightness.dark),
      );
      expect(tester.takeException(), isNull);
    });
  });

  test('formatModelSize', () {
    expect(formatModelSize(l10n, 2 * _gib + _gib ~/ 2), '2.5 GB');
    expect(formatModelSize(l10n, 512 * 1024 * 1024), '512.0 MB');
  });
}

OnDeviceModelOutcome _failed(
  OnDeviceModelErrorKind kind, {
  int? status,
  String? mirror,
}) => OnDeviceModelOutcome(
  model: 'qwen',
  operation: OnDeviceModelOperation.download,
  succeeded: false,
  error: OnDeviceModelError(kind, statusCode: status, mirror: mirror),
);
