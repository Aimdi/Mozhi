import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/fake_offline.dart';
import '../helpers/helpers.dart';

/// The labels (or tooltips) of the semantics nodes under [finder], in
/// screen reader order.
List<String> _readingOrder(WidgetTester tester, Finder finder) {
  final labels = <String>[];
  void visit(SemanticsNode node) {
    final text = node.label.isNotEmpty ? node.label : node.tooltip;
    if (text.isNotEmpty) labels.add(text);
    node
        .debugListChildrenInOrder(DebugSemanticsDumpOrder.traversalOrder)
        .forEach(visit);
  }

  visit(tester.getSemantics(finder));
  return labels;
}

int _indexOf(List<String> labels, Pattern pattern) =>
    labels.indexWhere((label) => label.contains(pattern));

/// Records every layout error (overflows) while [body] runs.
Future<List<String>> _layoutErrors(Future<void> Function() body) async {
  final errors = <String>[];
  final previous = FlutterError.onError;
  FlutterError.onError = (details) => errors.add(details.toString());
  try {
    await body();
  } finally {
    FlutterError.onError = previous;
  }
  return errors;
}

/// An AI translation with every extra: refinement chips, insights,
/// alignment, the meaning check, romanization, extra languages.
TranslateState _everything() =>
    translatedState(
      engine: claude,
      result: const TranslationResult(
        engineId: 'ai:claude',
        engineName: 'Claude',
        text: 'Bonjour le monde, comment allez-vous aujourd’hui ?',
        detectedSource: 'en',
        elapsed: Duration(milliseconds: 1200),
        destination: PublicInstanceDestination('mozhi.example.org'),
      ),
    ).copyWith(
      extraTargets: const [german, japanese],
      meaningStatus: ExtraStatus.loading,
    );

void main() {
  setUpAll(registerTranslateFallbacks);

  group('completion announcements', () {
    testWidgets('each finished translation is announced once', (tester) async {
      final translating = readyState(
        input: 'Hello world',
        status: TranslateStatus.translating,
      );
      final done = translatedState();
      final states = StreamController<TranslateState>();
      addTearDown(states.close);
      final harness = TranslateHarness(state: readyState(input: 'Hello world'));
      whenListen(
        harness.translate,
        states.stream,
        initialState: readyState(input: 'Hello world'),
      );
      await harness.pump(
        tester,
        child: const OutputCard(),
        supportsAnnounce: true,
      );

      Future<void> emit(TranslateState state) async {
        states.add(state);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }

      await emit(translating);
      expect(tester.takeAnnouncements(), isEmpty);
      await emit(done);
      expect(tester.takeAnnouncements(), [
        isAccessibilityAnnouncement('Bonjour le monde'),
      ]);
      // Other changes of the same translation say nothing.
      await emit(done.copyWith(insightsStatus: ExtraStatus.loading));
      await emit(done.copyWith(insightsStatus: ExtraStatus.ready));
      expect(tester.takeAnnouncements(), isEmpty);
      // The same text translated again is a new translation.
      await emit(translating);
      await emit(done);
      expect(tester.takeAnnouncements(), [
        isAccessibilityAnnouncement('Bonjour le monde'),
      ]);
    });
  });

  group('reading order', () {
    for (final (name, size) in [
      ('phone', const Size(400, 1400)),
      ('two panes', const Size(1200, 1400)),
    ]) {
      testWidgets('source, then result, then actions ($name)', (tester) async {
        final handle = tester.ensureSemantics();
        final harness = TranslateHarness(state: translatedState());
        await harness.pump(tester, size: size);
        final labels = _readingOrder(tester, find.byType(Scaffold).first);
        final source = _indexOf(labels, 'Source language');
        final input = _indexOf(labels, 'Text to translate');
        // Exactly: "Translation options" (the bar) comes first.
        final result = labels.indexOf('Translation');
        final copy = _indexOf(labels, 'Copy');
        final more = labels.indexOf('More');
        expect(
          [source, input, result, copy, more].every((i) => i >= 0),
          isTrue,
          reason: '$labels',
        );
        expect(source, lessThan(input));
        expect(input, lessThan(result));
        expect(result, lessThan(copy));
        expect(copy, lessThan(more));
        handle.dispose();
      });
    }
  });

  group('200% text on a 360 dp phone', () {
    testWidgets('the screen fits, More area open or closed', (tester) async {
      final harness = TranslateHarness(
        state: _everything(),
        settings: const AppSettings(
          recentPairs: [LanguagePair(source: english, target: german)],
        ),
      );
      final errors = await _layoutErrors(() async {
        await harness.pump(tester, size: const Size(360, 740), textScale: 2);
        await tester.pump(const Duration(milliseconds: 300));
        await openMore(tester);
        final list = find.byKey(const Key('translate_narrow_layout'));
        for (var i = 0; i < 8; i++) {
          await tester.drag(list, const Offset(0, -400));
          await tester.pump();
        }
        await tester.drag(list, const Offset(0, 4000));
        await tester.pump();
        // Closed again.
        final toggle = find.byKey(const Key('translate_more_toggle'));
        await tester.ensureVisible(toggle);
        await tester.tap(toggle);
        await tester.pump(const Duration(milliseconds: 300));
      });
      expect(errors, isEmpty);
      expect(find.byType(OutputCard), findsOneWidget);
    });

    testWidgets('the empty state, errors and progress fit', (tester) async {
      for (final state in [
        readyState(input: 'Hello'),
        readyState(input: 'Hello', status: TranslateStatus.translating),
        readyState(input: 'Hello').copyWith(
          status: TranslateStatus.failure,
          error: () => const MozhiApiException('Connection refused'),
        ),
        readyState(input: 'Hello').copyWith(
          status: TranslateStatus.failure,
          error: () => const OfflineModelMissingException(['de']),
        ),
      ]) {
        final harness = TranslateHarness(state: state);
        final errors = await _layoutErrors(() async {
          await harness.pump(
            tester,
            size: const Size(360, 740),
            textScale: 2,
            offline: fakeBergamot(),
          );
          await tester.pump(const Duration(milliseconds: 300));
        });
        expect(errors, isEmpty, reason: '$state');
      }
    });

    testWidgets('the language picker fits', (tester) async {
      final harness = TranslateHarness(
        state: translatedState(),
        settings: const AppSettings(
          recentLanguages: [german],
          pinnedLanguages: [japanese],
        ),
      );
      final errors = await _layoutErrors(() async {
        await harness.pump(
          tester,
          size: const Size(360, 740),
          textScale: 2,
          offline: FakeOfflineTranslator(downloaded: {'de', 'ja'}),
        );
        await tester.tap(find.byKey(const Key('translate_source_button')));
        await tester.pumpAndSettle();
        await tester.drag(
          find.byKey(const Key('translate_language_list')),
          const Offset(0, -1500),
        );
        await tester.pump();
      });
      expect(errors, isEmpty);
      expect(find.byType(LanguagePickerSheet), findsOneWidget);
    });

    testWidgets('compare mode fits', (tester) async {
      final harness = TranslateHarness(
        state: translatedState().copyWith(compareMode: true),
      );
      final errors = await _layoutErrors(() async {
        await harness.pump(tester, size: const Size(360, 740), textScale: 2);
        await tester.pump();
      });
      expect(errors, isEmpty);
      expect(find.byType(ComparePanel), findsOneWidget);
    });
  });
}
