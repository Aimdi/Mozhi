import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/widgets/instance_switcher.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

const _first = MozhiInstance(url: 'https://a.example', label: 'Mine');
const _second = MozhiInstance(url: 'https://b.example', label: 'Public');

void main() {
  setUpAll(registerTranslateFallbacks);

  group('switchInstanceAndRetry', () {
    late TranslateHarness harness;

    setUp(() {
      harness = TranslateHarness(
        settings: const AppSettings(instances: [_first, _second]),
      );
      when(() => harness.settings.preferInstance(any())).thenReturn(null);
    });

    Future<void> open(WidgetTester tester) async {
      await harness.pump(
        tester,
        child: Builder(
          builder: (context) => TextButton(
            onPressed: () => unawaited(switchInstanceAndRetry(context)),
            child: const Text('Switch'),
          ),
        ),
      );
      await tester.tap(find.text('Switch'));
      await tester.pumpAndSettle();
    }

    testWidgets('picking the first server while requests start at another '
        '(it failed recently) puts it first again', (tester) async {
      when(() => harness.repository.activeInstance).thenReturn(_second);
      await open(tester);

      await tester.tap(find.text('Mine'));
      await tester.pumpAndSettle();

      verify(() => harness.settings.preferInstance(_first.url)).called(1);
      verify(() => harness.repository.preferInstance(_first.url)).called(1);
      verify(harness.translate.translate).called(1);
    });

    testWidgets('picking another server tells the repository too', (
      tester,
    ) async {
      await open(tester);

      await tester.tap(find.text('Public'));
      await tester.pumpAndSettle();

      verify(() => harness.settings.preferInstance(_second.url)).called(1);
      verify(() => harness.repository.preferInstance(_second.url)).called(1);
      verify(harness.translate.translate).called(1);
    });

    testWidgets('picking the server in use changes nothing', (tester) async {
      await open(tester);

      await tester.tap(find.text('Mine'));
      await tester.pumpAndSettle();

      verifyNever(() => harness.repository.preferInstance(any()));
      verifyNever(harness.translate.translate);
    });
  });
}
