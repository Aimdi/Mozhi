import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/web_translate/web_translate.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

const page = ReadablePage(
  title: 'Title',
  blocks: [
    ReadableBlock(kind: ReadableBlockKind.heading2, text: 'Heading'),
    ReadableBlock(kind: ReadableBlockKind.paragraph, text: 'Para'),
    ReadableBlock(kind: ReadableBlockKind.listItem, text: 'Bullet'),
    ReadableBlock(
      kind: ReadableBlockKind.listItem,
      text: 'Numbered',
      number: 2,
      depth: 1,
    ),
    ReadableBlock(kind: ReadableBlockKind.quote, text: 'Line 1\nLine 2'),
    ReadableBlock(kind: ReadableBlockKind.code, text: 'code()'),
    ReadableBlock(kind: ReadableBlockKind.image, text: 'Alt'),
  ],
);

void main() {
  group('WebTranslateState', () {
    test('counts items and progress', () {
      const empty = WebTranslateState();
      expect(empty.totalItems, 0);
      expect(empty.doneItems, 0);
      expect(empty.progress, 0);
      expect(empty.hasUntranslated, isFalse);
      expect(empty.plainText(), '');
      expect(empty.displayTitle, '');

      const state = WebTranslateState(
        page: page,
        translations: ['Encabezado', null, 'Viñeta', null, null, null, null],
        translatedTitle: 'Título',
      );
      expect(state.totalItems, 7);
      expect(state.doneItems, 3);
      expect(state.progress, closeTo(3 / 7, 1e-9));
      expect(state.hasUntranslated, isTrue);
      expect(state.translationAt(0), 'Encabezado');
      expect(state.translationAt(99), isNull);
      expect(state.displayTitle, 'Título');
      expect(state.hasPage, isTrue);
    });

    test('a page without a title has one item less', () {
      const state = WebTranslateState(
        page: ReadablePage(
          title: ' ',
          blocks: [ReadableBlock(kind: ReadableBlockKind.paragraph, text: 'x')],
        ),
      );
      expect(state.totalItems, 1);
      expect(state.displayTitle, ' ');
    });

    test('busy while loading or translating', () {
      expect(
        const WebTranslateState(status: WebTranslateStatus.loading).isBusy,
        isTrue,
      );
      expect(
        const WebTranslateState(status: WebTranslateStatus.translating).isBusy,
        isTrue,
      );
      expect(
        const WebTranslateState(status: WebTranslateStatus.stopped).isBusy,
        isFalse,
      );
    });

    test('plainText renders the translation with fallbacks', () {
      const state = WebTranslateState(
        page: page,
        translations: [
          'Encabezado',
          'Párrafo',
          null,
          'Numerado',
          null,
          null,
          'Alt ES',
        ],
        translatedTitle: 'Título',
      );
      expect(
        state.plainText(),
        'Título\n\nEncabezado\n\nPárrafo\n\n• Bullet\n\n  2. Numerado\n\n'
        '> Line 1\n> Line 2\n\ncode()\n\n[Alt ES]',
      );
      expect(
        state.plainText(translated: false),
        'Title\n\nHeading\n\nPara\n\n• Bullet\n\n  2. Numbered\n\n'
        '> Line 1\n> Line 2\n\ncode()\n\n[Alt]',
      );
    });

    test('copyWith replaces and clears values', () {
      const state = WebTranslateState(
        url: 'a',
        page: page,
        error: 'e',
        selection: googleToSpanish,
        translatedTitle: 't',
        detectedSource: 'en',
        unsupportedCharset: 'big5',
      );
      final copy = state.copyWith(
        url: 'b',
        urlInvalid: true,
        status: WebTranslateStatus.translated,
        pageUri: () => Uri.parse('https://x.y'),
        page: () => null,
        truncated: true,
        unsupportedCharset: () => null,
        translations: const ['x'],
        translatedTitle: () => null,
        selection: () => null,
        detectedSource: () => null,
        error: () => null,
        mode: ReaderMode.sideBySide,
      );
      expect(copy.url, 'b');
      expect(copy.urlInvalid, isTrue);
      expect(copy.status, WebTranslateStatus.translated);
      expect(copy.pageUri, Uri.parse('https://x.y'));
      expect(copy.page, isNull);
      expect(copy.truncated, isTrue);
      expect(copy.unsupportedCharset, isNull);
      expect(copy.translations, ['x']);
      expect(copy.translatedTitle, isNull);
      expect(copy.selection, isNull);
      expect(copy.detectedSource, isNull);
      expect(copy.error, isNull);
      expect(copy.mode, ReaderMode.sideBySide);
      expect(state.copyWith(), state);
    });

    test('selections compare by value', () {
      expect(
        googleToSpanish,
        const WebTranslateSelection(
          engine: googleEngine,
          source: Language.auto,
          target: spanish,
        ),
      );
      expect(
        googleToSpanish ==
            const WebTranslateSelection(
              engine: googleEngine,
              source: Language.auto,
              target: arabic,
            ),
        isFalse,
      );
    });
  });
}
