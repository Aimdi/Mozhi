import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/onboarding/onboarding.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import 'helpers.dart';

const out = '/tmp/claude-0/-home-user-Mozhi/071da89e-592f-547c-b32a-54fb03071e39/scratchpad/shots';

void main() {
  setUpAll(registerOnboardingFallbacks);
  for (final (name, size, scale, dark) in [
    ('phone', const Size(360, 760), 1.0, false),
    ('phone_big_text', const Size(320, 640), 2.0, true),
    ('tablet', const Size(1200, 800), 1.0, true),
  ]) {
    testWidgets('screens $name', (tester) async {
      tester.view
        ..physicalSize = size
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repo = MockTranslationRepository();
      when(() => repo.pingInstance(any())).thenAnswer((i) async {
        final inst = i.positionalArguments.first as MozhiInstance;
        if (inst.url == instanceB.url) throw const MozhiApiException('down');
        return Duration(milliseconds: inst.url.length * 17);
      });
      final settings = createSettings();
      final key = GlobalKey();
      await tester.pumpWidget(
        RepositoryProvider<TranslationRepository>.value(
          value: repo,
          child: BlocProvider<SettingsCubit>.value(
            value: settings,
            child: InheritedGoRouter(
              goRouter: MockGoRouter(),
              child: RepaintBoundary(
                key: key,
                child: MaterialApp(
                  theme: ThemeData(useMaterial3: true),
                  darkTheme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
                  themeMode: dark ? ThemeMode.dark : ThemeMode.light,
                  localizationsDelegates: AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!,
                  ),
                  home: const OnboardingPage(),
                ),
              ),
            ),
          ),
        ),
      );
      Future<void> shot(String step) async {
        await tester.pumpAndSettle();
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          File('$out/${name}_$step.png').writeAsBytesSync(bytes!.buffer.asUint8List());
        });
      }
      await shot('1_welcome');
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Find the fastest public instance'), 200, scrollable: find.descendant(of: find.byType(ServiceStep), matching: find.byType(Scrollable)).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Find the fastest public instance'));
      await shot('2_service');
      await tester.scrollUntilVisible(find.text('Test & add'), 200, scrollable: find.descendant(of: find.byType(ServiceStep), matching: find.byType(Scrollable)).first);
      await shot('2b_service');
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Ollama'), 200, scrollable: find.descendant(of: find.byType(AiStep), matching: find.byType(Scrollable)).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ollama'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(const Key('onboarding-base-url')), 200, scrollable: find.descendant(of: find.byType(AiStep), matching: find.byType(Scrollable)).first);
      await shot('3_ai');
      await tester.tap(find.text('Next'));
      await shot('4_done');
      expect(tester.takeException(), isNull);
    });
  }
}
