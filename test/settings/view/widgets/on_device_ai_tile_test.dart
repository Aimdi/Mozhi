import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/on_device_ai/data/on_device_models.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/models/settings_category.dart';
import 'package:mozhi/settings/view/categories/ai_settings.dart';
import 'package:mozhi/settings/view/categories/engine_settings.dart';
import 'package:mozhi/settings/view/settings_search_index.dart';
import 'package:mozhi/settings/view/widgets/on_device_ai_tile.dart';
import 'package:mozhi/settings/view/widgets/settings_search.dart';

import '../../../translate/helpers/fake_on_device_models.dart';
import '../helpers.dart';

void main() {
  setUpAll(registerFallbacks);

  late FakeOnDeviceModels models;
  late MockGoRouter router;

  setUp(() {
    models = FakeOnDeviceModels(testCatalog);
    router = createRouter();
    when(() => router.push<void>(any())).thenAnswer((_) async {});
    addTearDown(models.controller.close);
  });

  Future<void> pump(WidgetTester tester, Widget child, {bool provided = true}) {
    final body = Scaffold(body: ListView(children: [child]));
    return tester.pumpView(
      provided
          ? RepositoryProvider<OnDeviceModels>.value(value: models, child: body)
          : body,
      router: router,
    );
  }

  group(OnDeviceAiTile, () {
    testWidgets('describes on-device AI and opens its settings', (
      tester,
    ) async {
      await pump(tester, const OnDeviceAiTile());
      expect(find.text('On-device AI'), findsOneWidget);
      expect(
        find.text(
          'AI translation and extras that run on this phone, without the '
          'network',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('settings_on_device_ai')));
      verify(() => router.push<void>(AppRoutes.onDeviceAi)).called(1);
    });

    testWidgets('names the models in use, and follows changes', (tester) async {
      models.translationModel = 'hy-mt2-1.8b-q4';
      await pump(tester, const OnDeviceAiTile());
      expect(find.text('In use: Hy-MT2 1.8B'), findsOneWidget);

      models.assistantModel = 'qwen3-1.7b-q4';
      models.controller.add(null);
      await tester.pump();
      expect(find.text('In use: Hy-MT2 1.8B, Qwen3 1.7B'), findsOneWidget);
    });

    testWidgets('says what it needs where it cannot run', (tester) async {
      await pump(tester, const OnDeviceAiTile(), provided: false);
      expect(find.text('Needs the Android app on a 64-bit phone'), findsOne);
      final tile = tester.widget<ListTile>(
        find.byKey(const Key('settings_on_device_ai_unavailable')),
      );
      expect(tile.onTap, isNull);
    });
  });

  group(OnDeviceAiOfflineEntry, () {
    testWidgets('opens the On-device AI settings', (tester) async {
      await pump(tester, const OnDeviceAiOfflineEntry());
      expect(
        find.text(
          'AI translation and extras without the network (larger downloads)',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('offline_on_device_ai')));
      verify(() => router.push<void>(AppRoutes.onDeviceAi)).called(1);
    });

    testWidgets('is not shown where on-device AI cannot run', (tester) async {
      await pump(tester, const OnDeviceAiOfflineEntry(), provided: false);
      expect(find.byType(ListTile), findsNothing);
    });
  });

  group('settings', () {
    testWidgets('AI settings start with on-device AI', (tester) async {
      await pump(tester, const AiSettings(settings: AppSettings()));
      final onDevice = find.byKey(SettingsAnchor.highlightKey('on_device_ai'));
      expect(onDevice, findsOneWidget);
      expect(
        tester.getTopLeft(onDevice).dy,
        lessThan(
          tester.getTopLeft(find.byKey(const Key('settings_ai_providers'))).dy,
        ),
      );
    });

    testWidgets('Translation engines link to it where it runs', (tester) async {
      await pump(tester, const EngineSettings(settings: AppSettings()));
      expect(
        find.byKey(SettingsAnchor.highlightKey('engines_on_device_ai')),
        findsOneWidget,
      );
      await pump(
        tester,
        const EngineSettings(settings: AppSettings()),
        provided: false,
      );
      expect(
        find.byKey(SettingsAnchor.highlightKey('engines_on_device_ai')),
        findsNothing,
      );
    });

    for (final provided in [true, false]) {
      testWidgets('search finds it (${provided ? 'Android' : 'web'})', (
        tester,
      ) async {
        late List<SettingsSearchEntry> entries;
        await pump(
          tester,
          Builder(
            builder: (context) {
              entries = settingsSearchIndex(context, const AppSettings());
              return const SizedBox.shrink();
            },
          ),
          provided: provided,
        );
        final found = {
          for (final entry in entries)
            if (entry.title == 'On-device AI') entry.anchor: entry,
        };
        expect(found['on_device_ai']?.category, SettingsCategory.ai);
        expect(
          found['on_device_ai']?.subtitle,
          provided
              ? 'AI translation and extras that run on this phone, without '
                    'the network'
              : 'Needs the Android app on a 64-bit phone',
        );
        expect(found['on_device_ai']?.keywords.single, contains('llama.cpp'));
        expect(
          found['engines_on_device_ai']?.category,
          provided ? SettingsCategory.engines : null,
        );
      });
    }
  });
}
