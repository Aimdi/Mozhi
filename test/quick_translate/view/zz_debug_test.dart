import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/quick_translate/quick_translate.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

void main() {
  setUpAll(registerQuickTranslateFallbacks);
  late MockTranslationRepository repository;
  late MockSettingsCubit settings;
  setUp(() {
    repository = MockTranslationRepository();
    settings = mockSettings(const AppSettings(target: french));
    when(() => repository.getEngines(refresh: any(named: 'refresh')))
        .thenAnswer((_) async => const [google, deepl]);
    when(() => repository.getTargetLanguages(any()))
        .thenAnswer((_) async => mozhiTargets);
  });
  Widget host(void Function(BuildContext context) onPressed) {
    return RepositoryProvider<TranslationRepository>.value(
      value: repository,
      child: BlocProvider<SettingsCubit>.value(
        value: settings,
        child: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => onPressed(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
  }
    testWidgets('closing cancels a running translation', (tester) async {
      debugPrint('DBG start');
      final controller = StreamController<TranslationResult>();
      when(() => repository.translate(any(), any()))
          .thenAnswer((_) => controller.stream);
      await tester.pumpQuick(
        host((context) => showQuickTranslate(context, text: 'Hello world')),
      );
      await tester.tap(find.text('open'));
      debugPrint('DBG tapped open');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(controller.hasListener, isTrue);
      debugPrint('DBG listening');

      await tester.tap(find.byTooltip('Close'));
      debugPrint('DBG tapped close');
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(controller.hasListener, isFalse);
      debugPrint('DBG cancelled');
      unawaited(controller.close());
      debugPrint('DBG end');
    }, timeout: const Timeout(Duration(seconds: 40)));
}
