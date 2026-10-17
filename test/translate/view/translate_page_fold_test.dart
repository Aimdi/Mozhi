import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/view/app_shell.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

/// A Surface Duo style hinge: 34 dp between two 540 dp screens.
const _duoHinge = DisplayFeature(
  bounds: Rect.fromLTWH(540, 0, 34, 720),
  type: DisplayFeatureType.hinge,
  state: DisplayFeatureState.unknown,
);

/// A two-screen device spanned in book posture.
const _duoSize = Size(1114, 720);

DisplayFeature _fold(
  Rect bounds, {
  DisplayFeatureState state = DisplayFeatureState.postureHalfOpened,
}) =>
    DisplayFeature(bounds: bounds, type: DisplayFeatureType.fold, state: state);

final Finder _inputPane = find.byKey(const Key('translate_input_pane'));
final Finder _outputPane = find.byKey(const Key('translate_output_pane'));

/// The vertical hairline between the side-by-side panes.
final Finder _paneHairline = find.byWidgetPredicate(
  (widget) => widget is Hairline && widget.vertical,
);

void main() {
  setUpAll(registerTranslateFallbacks);

  /// Pumps the translate screen in a [size] window with [features], then
  /// a frame more (the split follows its position after the first layout).
  Future<TranslateHarness> pumpWithFeatures(
    WidgetTester tester, {
    required Size size,
    required List<DisplayFeature> features,
  }) async {
    final harness = TranslateHarness(state: translatedState());
    tester.view.displayFeatures = features;
    addTearDown(tester.view.resetDisplayFeatures);
    await harness.pump(tester, size: size);
    await tester.pump();
    return harness;
  }

  /// Pumps [TranslateView] inside the app's [AppShell] (navigation rail
  /// from 840 dp), like the app.
  Future<void> pumpInShell(
    WidgetTester tester, {
    required Size size,
    required List<DisplayFeature> features,
    TextDirection textDirection = TextDirection.ltr,
  }) async {
    final harness = TranslateHarness(state: translatedState());
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = size
      ..displayFeatures = features;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      InheritedGoRouter(
        goRouter: harness.router,
        child: MultiRepositoryProvider(
          providers: [
            RepositoryProvider<SpeechService>.value(value: harness.speech),
            RepositoryProvider<TranslationRepository>.value(
              value: harness.repository,
            ),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider<TranslateCubit>.value(value: harness.translate),
              BlocProvider<SettingsCubit>.value(value: harness.settings),
              BlocProvider<HistoryCubit>.value(value: harness.history),
            ],
            child: MaterialApp(
              theme: ThemeData(useMaterial3: true),
              localizationsDelegates: appLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Directionality(
                textDirection: textDirection,
                child: AppShell(
                  selectedIndex: 0,
                  onDestinationSelected: (_) {},
                  child: const TranslateView(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('TranslateView on foldables', () {
    testWidgets('splits input and output at a vertical hinge', (tester) async {
      await pumpWithFeatures(tester, size: _duoSize, features: [_duoHinge]);
      expect(find.byKey(const Key('translate_wide_layout')), findsOneWidget);
      final input = tester.getRect(_inputPane);
      final output = tester.getRect(_outputPane);
      expect(input.right, 540);
      expect(output.left, 574);
      expect(tester.getRect(find.byType(InputCard)).right, lessThan(540));
      expect(tester.getRect(find.byType(OutputCard)).left, greaterThan(574));
      // The languages head the input pane: nothing under the hinge.
      final languages = tester.getRect(find.byType(LanguageBar));
      expect(languages.right, lessThanOrEqualTo(540));
      expect(languages.bottom, lessThanOrEqualTo(input.top));
      // The hinge separates the panes; no hairline is drawn.
      expect(tester.getSize(_paneHairline), Size.zero);
    });

    testWidgets('splits at a half-opened fold on a narrow window', (
      tester,
    ) async {
      // A book-style foldable's inner screen, below the wide breakpoint.
      await pumpWithFeatures(
        tester,
        size: const Size(690, 830),
        features: [_fold(const Rect.fromLTWH(345, 0, 0, 830))],
      );
      expect(find.byKey(const Key('translate_narrow_layout')), findsNothing);
      expect(tester.getRect(_inputPane).right, 345);
      expect(tester.getRect(_outputPane).left, 345);
    });

    testWidgets('keeps one column at a flat fold', (tester) async {
      await pumpWithFeatures(
        tester,
        size: const Size(690, 830),
        features: [
          _fold(
            const Rect.fromLTWH(345, 0, 0, 830),
            state: DisplayFeatureState.postureFlat,
          ),
        ],
      );
      expect(find.byKey(const Key('translate_narrow_layout')), findsOneWidget);
      expect(find.byKey(const Key('translate_wide_layout')), findsNothing);
    });

    testWidgets('puts the input above a tabletop fold on a phone', (
      tester,
    ) async {
      await pumpWithFeatures(
        tester,
        size: const Size(412, 900),
        features: [_fold(const Rect.fromLTWH(0, 450, 412, 0))],
      );
      final input = tester.getRect(_inputPane);
      final output = tester.getRect(_outputPane);
      expect(input.bottom, 450);
      expect(output.top, 450);
      expect(input.width, output.width);
      // The languages stay on top, across the screen.
      final languages = tester.getRect(find.byType(LanguageBar));
      expect(languages.bottom, lessThanOrEqualTo(input.top));
      expect(tester.getRect(find.byType(InputCard)).top, lessThan(450));
      expect(tester.getRect(find.byType(OutputCard)).top, greaterThan(450));
    });

    testWidgets('puts the input above a tabletop fold on a wide window', (
      tester,
    ) async {
      await pumpWithFeatures(
        tester,
        size: const Size(1280, 800),
        features: [_fold(const Rect.fromLTWH(0, 420, 1280, 0))],
      );
      expect(tester.getRect(_inputPane).bottom, 420);
      expect(tester.getRect(_outputPane).top, 420);
      expect(_paneHairline, findsNothing);
    });

    testWidgets('lays out as before without a display feature', (tester) async {
      await pumpWithFeatures(tester, size: _duoSize, features: const []);
      final input = tester.getRect(_inputPane);
      final output = tester.getRect(_outputPane);
      // Two equal panes around a 1 dp hairline, 24 dp from the edges.
      expect(input.left, 24);
      expect(output.right, _duoSize.width - 24);
      expect(input.width, output.width);
      expect(output.left - input.right, 1);
      expect(tester.getSize(_paneHairline).width, 1);
      // The languages span both panes.
      expect(tester.getRect(find.byType(LanguageBar)).width, 1114 - 48);
    });
  });

  group('AppShell on foldables', () {
    testWidgets('keeps the rail clear of the hinge and splits at it', (
      tester,
    ) async {
      await pumpInShell(tester, size: _duoSize, features: [_duoHinge]);
      final rail = tester.getRect(find.byType(NavigationRail));
      expect(rail.left, 0);
      expect(rail.right, lessThanOrEqualTo(_duoHinge.bounds.left));
      // The translate screen starts after the rail; its panes still split
      // exactly at the hinge.
      expect(tester.getRect(_inputPane).left, greaterThan(rail.right));
      expect(tester.getRect(_inputPane).right, 540);
      expect(tester.getRect(_outputPane).left, 574);
    });

    testWidgets('in RTL keeps the rail at the right edge, start pane right '
        'of the hinge', (tester) async {
      await pumpInShell(
        tester,
        size: _duoSize,
        features: [_duoHinge],
        textDirection: TextDirection.rtl,
      );
      final rail = tester.getRect(find.byType(NavigationRail));
      expect(rail.right, _duoSize.width);
      expect(rail.left, greaterThanOrEqualTo(_duoHinge.bounds.right));
      expect(tester.getRect(_inputPane).left, 574);
      expect(tester.getRect(_outputPane).right, 540);
    });
  });
}
