import 'dart:async';

import 'package:bergamot_translator/bergamot_translator.dart'
    show MeteredConnectionException;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/fake_offline.dart';
import '../helpers/helpers.dart';

/// An offline engine with English, German, French and Japanese that
/// records its downloads; with [metered] a Wi-Fi-only download fails like
/// Bergamot's on mobile data.
class _RecordingOffline implements OfflineTranslator {
  new({
    Set<String> downloaded = const {},
    this.metered = false,
    this.slow = false,
  }) : downloaded = {'en', ...downloaded};

  final Set<String> downloaded;
  final bool metered;

  /// Whether downloads wait for [finish].
  final bool slow;
  final _finished = Completer<void>();

  /// Lets the downloads of a [slow] engine finish.
  void finish() => _finished.complete();

  /// The downloads asked for: the code and whether Wi-Fi only.
  final downloads = <(String, bool)>[];

  @override
  bool get isAvailable => true;

  @override
  Set<String> get supportedLanguages => const {'en', 'de', 'fr', 'ja'};

  @override
  Future<Set<String>> downloadedLanguages() async => {...downloaded};

  @override
  Future<void> downloadLanguage(String code, {bool wifiOnly = true}) async {
    downloads.add((code, wifiOnly));
    if (metered && wifiOnly) throw const MeteredConnectionException();
    if (slow) await _finished.future;
    downloaded.add(code);
  }

  @override
  Future<void> deleteLanguage(String code) async {}

  @override
  Future<String> translate(
    String text, {
    required String source,
    required String target,
  }) async => text;

  @override
  Future<String?> identifyLanguage(String text) async => null;

  @override
  Future<void> dispose() async {}
}

/// [_RecordingOffline] whose downloads run until [cancelDownload] stops
/// them (or [finish] ends them).
class _CancellableOffline extends _RecordingOffline
    implements CancellableDownloads {
  new() : super(slow: true);

  final cancelled = <String>[];
  Completer<void>? _running;

  @override
  Future<void> downloadLanguage(String code, {bool wifiOnly = true}) async {
    downloads.add((code, wifiOnly));
    final running = _running = Completer<void>();
    await Future.any([running.future, _finished.future]);
    if (running.isCompleted) throw OfflineDownloadCancelledException(code);
    downloaded.add(code);
  }

  @override
  Future<void> cancelDownload(String code) async {
    cancelled.add(code);
    final running = _running;
    if (running != null && !running.isCompleted) running.complete();
  }
}

/// [finder] inside the language picker.
Finder _inPicker(Finder finder) =>
    find.descendant(of: find.byType(LanguagePickerSheet), matching: finder);

Finder _offlineMark(String code) =>
    find.byKey(ValueKey('translate_language_offline:$code'));

Finder _download(String code) =>
    find.byKey(ValueKey('translate_language_download:$code'));

/// The editable text of the picker's search field.
EditableText _search(WidgetTester tester) => tester.widget<EditableText>(
  find.descendant(
    of: find.byKey(const Key('translate_language_search')),
    matching: find.byType(EditableText),
  ),
);

void main() {
  setUpAll(registerTranslateFallbacks);

  Future<void> open(
    WidgetTester tester,
    TranslateHarness harness, {
    bool source = false,
    Size size = const Size(400, 1600),
    OfflineTranslator? offline,
    KeyValueStore? store,
  }) async {
    await harness.pump(
      tester,
      child: store == null
          ? const LanguageBar()
          : RepositoryProvider<KeyValueStore>.value(
              value: store,
              child: const LanguageBar(),
            ),
      size: size,
      offline: offline,
    );
    await tester.tap(
      find.byKey(
        Key(source ? 'translate_source_button' : 'translate_target_button'),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('search focus', () {
    test('languagePickerAutofocus: wide windows and after keyboard use', () {
      addTearDown(
        () => FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.automatic,
      );
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTouch;
      expect(languagePickerAutofocus(wide: true), isTrue);
      expect(languagePickerAutofocus(wide: false), isFalse);
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      expect(languagePickerAutofocus(wide: false), isTrue);
    });

    testWidgets('a tap on a phone leaves the keyboard down', (tester) async {
      await open(tester, TranslateHarness());
      expect(_search(tester).focusNode.hasFocus, isFalse);
    });

    testWidgets('wide windows focus the search field', (tester) async {
      await open(tester, TranslateHarness(), size: const Size(1000, 900));
      expect(_search(tester).focusNode.hasFocus, isTrue);
    });

    testWidgets('after keyboard use the search field has the focus', (
      tester,
    ) async {
      addTearDown(
        () => FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.automatic,
      );
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      await open(tester, TranslateHarness());
      expect(_search(tester).focusNode.hasFocus, isTrue);
    });

    testWidgets('a key typed on a phone starts the search', (tester) async {
      final harness = TranslateHarness();
      await open(tester, harness);
      // Modified keys are left alone.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ, character: 'j');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(_search(tester).controller.text, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ, character: 'j');
      await tester.pump();
      expect(_search(tester).controller.text, 'j');
      expect(_search(tester).focusNode.hasFocus, isTrue);
      expect(_inPicker(find.text('Japanese')), findsOneWidget);
      expect(_inPicker(find.text('German')), findsNothing);
      // Enter picks the first match, as when typed in the field.
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      verify(() => harness.translate.setTarget(japanese)).called(1);
    });

    testWidgets('Esc closes the picker', (tester) async {
      for (final size in [const Size(400, 1600), const Size(1000, 900)]) {
        final harness = TranslateHarness();
        await open(tester, harness, size: size);
        expect(find.byType(LanguagePickerSheet), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(LanguagePickerSheet), findsNothing, reason: '$size');
        verifyNever(() => harness.translate.setTarget(any()));
      }
    });
  });

  group('styles', () {
    testWidgets('sit behind their segment, after the languages', (
      tester,
    ) async {
      await open(tester, TranslateHarness(state: readyState(engine: claude)));
      final tabs = find.byKey(const Key('translate_language_tabs'));
      expect(tabs, findsOneWidget);
      expect(find.text('All languages'), findsOneWidget);
      expect(find.text('Pirate speak'), findsNothing);
      await tester.tap(find.text('Styles'));
      await tester.pumpAndSettle();
      expect(find.text('Pirate speak'), findsOneWidget);
      expect(find.text('All languages'), findsNothing);
      await tester.tap(find.text('Languages'));
      await tester.pumpAndSettle();
      expect(find.text('All languages'), findsOneWidget);
    });

    testWidgets('a search lists languages and styles, without the segment', (
      tester,
    ) async {
      await open(tester, TranslateHarness(state: readyState(engine: claude)));
      await tester.enterText(
        find.byKey(const Key('translate_language_search')),
        'speak',
      );
      await tester.pump();
      expect(find.byKey(const Key('translate_language_tabs')), findsNothing);
      expect(find.text('Pirate speak'), findsOneWidget);
    });

    testWidgets('are not offered for Mozhi engines', (tester) async {
      await open(tester, TranslateHarness());
      expect(find.byKey(const Key('translate_language_tabs')), findsNothing);
    });
  });

  group('pin button', () {
    testWidgets('shows on Recent and Pinned rows only', (tester) async {
      await open(
        tester,
        TranslateHarness(
          settings: const AppSettings(
            recentLanguages: [german],
            pinnedLanguages: [japanese],
          ),
        ),
      );
      expect(find.byTooltip('Pin German'), findsOneWidget);
      expect(find.byTooltip('Unpin Japanese'), findsOneWidget);
      expect(find.byTooltip('Pin French'), findsNothing);
    });

    testWidgets('shows while a row is hovered', (tester) async {
      final harness = TranslateHarness();
      await open(tester, harness);
      final row = _inPicker(find.text('French'));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(row));
      await tester.pump();
      expect(find.byTooltip('Pin French'), findsOneWidget);
      await tester.tap(find.byTooltip('Pin French'));
      verify(() => harness.settings.togglePinnedLanguage(french)).called(1);
      await mouse.moveTo(const Offset(1, 1));
      await tester.pump();
      expect(find.byTooltip('Pin French'), findsNothing);
    });

    testWidgets('shows while a row has the keyboard focus', (tester) async {
      await open(tester, TranslateHarness());
      final title = tester.element(_inPicker(find.text('German')));
      Focus.of(title).requestFocus();
      await tester.pumpAndSettle();
      expect(find.byTooltip('Pin German'), findsOneWidget);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(find.byTooltip('Pin German'), findsNothing);
    });

    testWidgets('is a control of its own beside the row', (tester) async {
      final handle = tester.ensureSemantics();
      await open(
        tester,
        TranslateHarness(
          settings: const AppSettings(recentLanguages: [german]),
        ),
      );
      final pin = tester.getSemantics(find.byTooltip('Pin German'));
      var parent = pin.parent;
      while (parent != null) {
        expect(
          parent.getSemanticsData().flagsCollection.isButton,
          isFalse,
          reason: 'the pin button is inside $parent',
        );
        parent = parent.parent;
      }
      // The row says what a long press does.
      final row = tester.getSemantics(_inPicker(find.text('German')).first);
      expect(row.getSemanticsData().flagsCollection.isButton, isTrue);
      expect(row.hintOverrides?.onLongPressHint, 'Pin German');
      handle.dispose();
    });
  });

  group('offline', () {
    testWidgets('marks the languages that work offline with the source', (
      tester,
    ) async {
      await open(
        tester,
        TranslateHarness(state: readyState(source: english)),
        offline: _RecordingOffline(downloaded: {'de'}),
      );
      // English → German works offline (English is the pivot).
      expect(_offlineMark('de'), findsNWidgets(2));
      expect(_offlineMark('fr'), findsNothing);
      expect(find.bySemanticsLabel(RegExp('Works offline')), findsWidgets);
    });

    testWidgets('marks a source only when the pair with the target works', (
      tester,
    ) async {
      // French (the target) is not on the device: no pair into it works,
      // though German is listed as downloaded.
      await open(
        tester,
        TranslateHarness(),
        source: true,
        offline: _RecordingOffline(downloaded: {'de', 'ja'}),
      );
      expect(
        find.byKey(const Key('translate_language_section_downloaded')),
        findsOneWidget,
      );
      expect(_offlineMark('de'), findsNothing);
      expect(_offlineMark('ja'), findsNothing);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      // Into German (on the device): Japanese and English work.
      await open(
        tester,
        TranslateHarness(state: readyState(target: german)),
        source: true,
        offline: _RecordingOffline(downloaded: {'de', 'ja'}),
      );
      expect(_offlineMark('ja'), findsWidgets);
      expect(_offlineMark('en'), findsWidgets);
      expect(_offlineMark('fr'), findsNothing);
    });

    testWidgets('marks nothing for a custom language', (tester) async {
      await open(
        tester,
        TranslateHarness(
          state: readyState(
            engine: claude,
            target: const Language.custom('Pirate speak'),
          ),
        ),
        source: true,
        offline: _RecordingOffline(downloaded: {'de'}),
      );
      expect(_offlineMark('de'), findsNothing);
    });

    testWidgets('offers the download of a missing language in its row', (
      tester,
    ) async {
      final offline = _RecordingOffline(downloaded: {'de'});
      await open(
        tester,
        TranslateHarness(),
        offline: offline,
        store: MemoryStore(),
      );
      // German is there, English is part of every model, Japanese and
      // French can be downloaded.
      expect(_download('de'), findsNothing);
      expect(_download('en'), findsNothing);
      expect(_download('ja'), findsWidgets);
      expect(find.byTooltip('Download French'), findsOneWidget);

      await tester.tap(_download('fr'));
      await tester.pumpAndSettle();
      expect(offline.downloads, [('fr', true)]);
      expect(find.text('French is ready for offline use'), findsOneWidget);
      // Now marked and listed as downloaded, and not offered again.
      expect(_offlineMark('fr'), findsWidgets);
      expect(_download('fr'), findsNothing);
      // Still open.
      expect(find.byType(LanguagePickerSheet), findsOneWidget);
    });

    testWidgets('asks before downloading over mobile data', (tester) async {
      final offline = _RecordingOffline(metered: true);
      await open(
        tester,
        TranslateHarness(),
        offline: offline,
        store: MemoryStore(),
      );
      await tester.tap(_download('fr'));
      await tester.pumpAndSettle();
      expect(find.text('Download over mobile data?'), findsOneWidget);
      await tester.tap(find.text('Download anyway'));
      await tester.pumpAndSettle();
      expect(offline.downloads, [('fr', true), ('fr', false)]);
      expect(find.text('French is ready for offline use'), findsOneWidget);
    });

    testWidgets('keeps the Wi-Fi only choice of the offline languages', (
      tester,
    ) async {
      final offline = _RecordingOffline(metered: true);
      await open(
        tester,
        TranslateHarness(),
        offline: offline,
        store: MemoryStore({'offline.wifiOnly': 'false'}),
      );
      await tester.tap(_download('fr'));
      await tester.pumpAndSettle();
      expect(find.text('Download over mobile data?'), findsNothing);
      expect(offline.downloads, [('fr', false)]);
    });

    testWidgets('a cancelled question downloads nothing', (tester) async {
      final offline = _RecordingOffline(metered: true);
      await open(
        tester,
        TranslateHarness(),
        offline: offline,
        store: MemoryStore(),
      );
      await tester.tap(_download('fr'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(offline.downloads, [('fr', true)]);
      expect(_download('fr'), findsWidgets);
    });

    testWidgets('names the download size when the engine knows it', (
      tester,
    ) async {
      await open(tester, TranslateHarness(), offline: fakeBergamot());
      await tester.pump();
      expect(find.byTooltip('Download German (24.0 MB)'), findsOneWidget);
    });

    testWidgets('shows the progress of a download', (tester) async {
      final offline = _RecordingOffline(slow: true);
      await open(
        tester,
        TranslateHarness(),
        offline: offline,
        store: MemoryStore(),
      );
      await tester.tap(_download('fr'));
      await tester.pump();
      await tester.pump();
      final progress = find.byKey(
        const ValueKey('translate_language_downloading:fr'),
      );
      expect(progress, findsWidgets);
      expect(find.bySemanticsLabel('Downloading…'), findsWidgets);
      offline.finish();
      await tester.pumpAndSettle();
      expect(progress, findsNothing);
      expect(_offlineMark('fr'), findsWidgets);
    });

    testWidgets('cancels a running download quietly', (tester) async {
      final semantics = tester.ensureSemantics();
      final offline = _CancellableOffline();
      await open(
        tester,
        TranslateHarness(),
        offline: offline,
        store: MemoryStore(),
      );
      await tester.tap(_download('fr'));
      await tester.pump();
      await tester.pump();
      final cancel = find.byKey(
        const ValueKey('translate_language_cancel_download:fr'),
      );
      expect(cancel, findsWidgets);
      // The plain progress ring is replaced by the Cancel button.
      expect(
        find.byKey(const ValueKey('translate_language_downloading:fr')),
        findsNothing,
      );
      expect(tester.getSize(cancel.first).height, greaterThanOrEqualTo(48));
      expect(tester.getSize(cancel.first).width, greaterThanOrEqualTo(48));
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Tooltip &&
              widget.message == 'Cancel downloading French',
        ),
        findsWidgets,
      );
      expect(find.bySemanticsLabel('Cancel downloading French'), findsWidgets);

      await tester.tap(cancel.first);
      await tester.pumpAndSettle();
      expect(offline.cancelled, ['fr']);
      expect(cancel, findsNothing);
      // Offered again, and nothing is said about it.
      expect(_download('fr'), findsWidgets);
      expect(find.byType(SnackBar), findsNothing);
      expect(_offlineMark('fr'), findsNothing);
      semantics.dispose();
    });

    testWidgets('an engine without cancel shows only the progress', (
      tester,
    ) async {
      final offline = _RecordingOffline(slow: true);
      await open(
        tester,
        TranslateHarness(),
        offline: offline,
        store: MemoryStore(),
      );
      await tester.tap(_download('fr'));
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(const ValueKey('translate_language_cancel_download:fr')),
        findsNothing,
      );
      offline.finish();
      await tester.pumpAndSettle();
    });

    testWidgets('offers no download outside the Android app', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await open(tester, TranslateHarness(), offline: _RecordingOffline());
        expect(_download('fr'), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('LanguageDropdownLayout', () {
    const window = BoxConstraints(maxWidth: 1280, maxHeight: 800);
    const anchor = Rect.fromLTWH(100, 50, 120, 48);

    test('opens under the anchor, aligned with its start', () {
      const layout = LanguageDropdownLayout(
        anchor: anchor,
        textDirection: TextDirection.ltr,
      );
      final child = layout.getConstraintsForChild(window);
      expect(child.biggest, languagePickerDropdownSize);
      expect(
        layout.getPositionForChild(window.biggest, child.biggest),
        const Offset(100, 98 + LanguageDropdownLayout.gap),
      );
    });

    test('stays inside the window, also right to left', () {
      const rtl = LanguageDropdownLayout(
        anchor: anchor,
        textDirection: TextDirection.rtl,
      );
      final child = rtl.getConstraintsForChild(window).biggest;
      expect(
        rtl.getPositionForChild(window.biggest, child).dx,
        LanguageDropdownLayout.margin,
      );
      const end = LanguageDropdownLayout(
        anchor: Rect.fromLTWH(1100, 50, 120, 48),
        textDirection: TextDirection.ltr,
      );
      expect(
        end.getPositionForChild(window.biggest, child).dx,
        1280 - LanguageDropdownLayout.margin - child.width,
      );
      // A narrower window: a narrower panel.
      const narrow = BoxConstraints(maxWidth: 900, maxHeight: 800);
      expect(
        rtl.getConstraintsForChild(narrow).maxWidth,
        900 - 2 * LanguageDropdownLayout.margin,
      );
    });

    test('opens above the anchor without room below', () {
      const layout = LanguageDropdownLayout(
        anchor: Rect.fromLTWH(100, 700, 120, 48),
        textDirection: TextDirection.ltr,
        padding: EdgeInsets.only(top: 24),
      );
      final child = layout.getConstraintsForChild(window).biggest;
      expect(child.height, languagePickerDropdownSize.height);
      expect(
        layout.getPositionForChild(window.biggest, child).dy,
        700 - LanguageDropdownLayout.gap - child.height,
      );
      expect(
        layout.shouldRelayout(
          const LanguageDropdownLayout(
            anchor: anchor,
            textDirection: TextDirection.ltr,
          ),
        ),
        isTrue,
      );
      expect(
        layout.shouldRelayout(
          const LanguageDropdownLayout(
            anchor: Rect.fromLTWH(100, 700, 120, 48),
            textDirection: TextDirection.ltr,
            padding: EdgeInsets.only(top: 24),
          ),
        ),
        isFalse,
      );
    });
  });
}
