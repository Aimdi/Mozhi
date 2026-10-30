import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/documents/pdf/pdf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(MethodChannelPdfPages.channelName);
  late List<MethodCall> calls;
  late Future<Object?> Function(MethodCall call) answer;

  setUp(() {
    calls = [];
    answer = (_) async => null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) {
          calls.add(call);
          return answer(call);
        });
  });

  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  final pages = MethodChannelPdfPages();

  group('MethodChannelPdfPages', () {
    test('uses the plugin channel and is supported', () {
      expect(MethodChannelPdfPages.channelName, 'mozhi/pdf_pages');
      expect(pages.isSupported, isTrue);
    });

    group('open', () {
      test('answers the page sizes in points', () async {
        answer = (_) async => {
          'widths': [612, 595],
          'heights': [792, 842],
        };
        final info = await pages.open('/cache/pdf_pages/a.pdf');
        expect(calls.single.method, 'open');
        expect(calls.single.arguments, {'path': '/cache/pdf_pages/a.pdf'});
        expect(info.pageCount, 2);
        expect(info.pageSizes, const [Size(612, 792), Size(595, 842)]);
        expect(
          info,
          const PdfInfo(pageSizes: [Size(612, 792), Size(595, 842)]),
        );
        expect(info.hashCode, isA<int>());
        expect('$info', 'PdfInfo(2 pages)');
      });

      Future<PdfOpenErrorKind?> kindOf() async {
        try {
          await pages.open('/cache/a.pdf');
          return null;
        } on PdfOpenException catch (error) {
          return error.kind;
        }
      }

      test('maps the platform errors', () async {
        for (final (code, kind) in [
          ('encrypted', PdfOpenErrorKind.encrypted),
          ('damaged', PdfOpenErrorKind.damaged),
          ('too_large', PdfOpenErrorKind.tooLarge),
          ('unsupported', PdfOpenErrorKind.unsupported),
          ('io', PdfOpenErrorKind.damaged),
          ('failed', PdfOpenErrorKind.damaged),
        ]) {
          answer = (_) async => throw PlatformException(code: code);
          expect(await kindOf(), kind, reason: code);
        }
      });

      test('is unsupported without the plugin', () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        expect(await kindOf(), PdfOpenErrorKind.unsupported);
      });

      test('checks what the platform answers', () async {
        for (final reply in <Object?>[
          null,
          {
            'widths': [612],
          },
          {
            'widths': [612, 612],
            'heights': [792],
          },
          {'widths': <int>[], 'heights': <int>[]},
          {
            'widths': [0],
            'heights': [792],
          },
          {
            'widths': ['612'],
            'heights': [792],
          },
        ]) {
          answer = (_) async => reply;
          expect(await kindOf(), PdfOpenErrorKind.damaged, reason: '$reply');
        }
        answer = (_) async => {
          'widths': List.filled(PdfLimits.maxPages + 1, 612),
          'heights': List.filled(PdfLimits.maxPages + 1, 792),
        };
        expect(await kindOf(), PdfOpenErrorKind.tooLarge);
      });
    });

    group('render', () {
      test('answers the pixels and asks for at most the limit', () async {
        final pixels = Uint8List(2 * 3 * 4);
        answer = (_) async => {
          'width': 2,
          'height': 3,
          'bytesPerPixel': 4,
          'pixels': pixels,
        };
        final image = await pages.render(4, maxPixels: 99000000);
        expect(calls.single.method, 'render');
        expect(calls.single.arguments, {
          'page': 4,
          'maxPixels': PdfLimits.maxPixels,
        });
        expect(image.width, 2);
        expect(image.height, 3);
        expect(image.bytesPerPixel, 4);
        expect(image.bytesPerLine, 8);
        expect(image.pixels, pixels);
        expect('$image', 'PdfPageImage(2x3, 4 bpp)');
      });

      test('takes grey pages, 4 bytes per pixel by default', () async {
        answer = (_) async => {
          'width': 2,
          'height': 2,
          'bytesPerPixel': 1,
          'pixels': Uint8List(4),
        };
        expect((await pages.render(0, maxPixels: 4)).bytesPerPixel, 1);
        answer = (_) async => {'width': 1, 'height': 1, 'pixels': Uint8List(4)};
        expect((await pages.render(0, maxPixels: 0)).bytesPerPixel, 4);
        expect(calls.last.arguments, {'page': 0, 'maxPixels': 1});
      });

      test('fails on errors and answers that do not add up', () async {
        answer = (_) async => throw PlatformException(code: 'not_open');
        await expectLater(
          pages.render(0, maxPixels: 10),
          throwsA(
            isA<PdfRenderException>()
                .having((e) => e.page, 'page', 0)
                .having((e) => e.cause, 'cause', 'not_open'),
          ),
        );
        for (final reply in <Object?>[
          null,
          {'width': 2, 'height': 2, 'pixels': Uint8List(15)},
          {
            'width': 2,
            'height': 2,
            'bytesPerPixel': 3,
            'pixels': Uint8List(12),
          },
          {'width': 0, 'height': 2, 'pixels': Uint8List(0)},
          {'width': 2, 'height': 0, 'pixels': Uint8List(0)},
          {'width': 4000, 'height': 4000, 'pixels': Uint8List(4)},
          {'width': '2', 'height': 2, 'pixels': Uint8List(16)},
        ]) {
          answer = (_) async => reply;
          await expectLater(
            pages.render(1, maxPixels: 10),
            throwsA(isA<PdfRenderException>()),
            reason: '$reply',
          );
        }
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        await expectLater(
          pages.render(1, maxPixels: 10),
          throwsA(isA<PdfRenderException>()),
        );
        expect(
          '${const PdfRenderException(page: 1, cause: 'x')}',
          'PdfRenderException(1, x)',
        );
      });
    });

    group('write', () {
      test('sends every page and block', () async {
        await pages.write('/cache/pdf_pages/out.pdf', const [
          PdfOutputPage(
            sourcePage: 0,
            size: Size(612, 792),
            blocks: [
              PdfTextBlock(
                rect: Rect.fromLTRB(10, 20, 300, 40),
                text: 'Hallo',
                color: Color(0xFF112233),
                background: Color(0xFFFFFFFF),
                direction: TextDirection.ltr,
                align: PdfTextAlign.center,
                fontSize: 14,
              ),
            ],
          ),
          PdfOutputPage(sourcePage: 1, size: Size(595, 842)),
        ]);
        expect(calls.single.method, 'write');
        expect(calls.single.arguments, {
          'path': '/cache/pdf_pages/out.pdf',
          'pages': [
            {
              'page': 0,
              'width': 612.0,
              'height': 792.0,
              'blocks': [
                {
                  'left': 10.0,
                  'top': 20.0,
                  'right': 300.0,
                  'bottom': 40.0,
                  'text': 'Hallo',
                  'color': 0xFF112233,
                  'background': 0xFFFFFFFF,
                  'rtl': false,
                  'align': 'center',
                  'fontSize': 14.0,
                },
              ],
            },
            {'page': 1, 'width': 595.0, 'height': 842.0, 'blocks': <Object>[]},
          ],
        });
      });

      test('marks right-to-left text', () async {
        await pages.write('/cache/out.pdf', const [
          PdfOutputPage(
            sourcePage: 0,
            size: Size(100, 100),
            blocks: [
              PdfTextBlock(
                rect: Rect.fromLTRB(0, 0, 50, 10),
                text: 'مرحبا',
                color: Color(0xFF000000),
                background: Color(0xFFFFFFFF),
                direction: TextDirection.rtl,
              ),
            ],
          ),
        ]);
        final arguments = calls.single.arguments as Map<Object?, Object?>;
        final page = (arguments['pages']! as List).single as Map;
        final block = (page['blocks'] as List).single as Map;
        expect(block['rtl'], isTrue);
        expect(block['align'], 'start');
        expect(block['fontSize'], 12.0);
      });

      test('fails with PdfWriteException', () async {
        answer = (_) async => throw PlatformException(code: 'io');
        await expectLater(
          pages.write('/cache/out.pdf', const []),
          throwsA(
            isA<PdfWriteException>().having((e) => e.cause, 'cause', 'io'),
          ),
        );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        await expectLater(
          pages.write('/cache/out.pdf', const []),
          throwsA(isA<PdfWriteException>()),
        );
        expect(
          '${const PdfWriteException(cause: 'io')}',
          'PdfWriteException(io)',
        );
      });
    });

    test('close ignores errors and a missing plugin', () async {
      await pages.close();
      expect(calls.single.method, 'close');
      answer = (_) async => throw PlatformException(code: 'closed');
      await pages.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await pages.close();
      expect(calls, hasLength(2));
    });
  });

  group('UnsupportedPdfPages', () {
    const unsupported = UnsupportedPdfPages();

    test('opens nothing', () async {
      expect(unsupported.isSupported, isFalse);
      await expectLater(
        unsupported.open('/a.pdf'),
        throwsA(const PdfOpenException(kind: PdfOpenErrorKind.unsupported)),
      );
      await expectLater(
        unsupported.render(2, maxPixels: 1),
        throwsA(isA<PdfRenderException>().having((e) => e.page, 'page', 2)),
      );
      await expectLater(
        unsupported.write('/a.pdf', const []),
        throwsA(isA<PdfWriteException>()),
      );
      await unsupported.close();
    });
  });

  group('PdfOpenException', () {
    test('compares by kind', () {
      const encrypted = PdfOpenException(kind: PdfOpenErrorKind.encrypted);
      expect(
        encrypted,
        const PdfOpenException(kind: PdfOpenErrorKind.encrypted),
      );
      expect(
        encrypted,
        isNot(const PdfOpenException(kind: PdfOpenErrorKind.damaged)),
      );
      expect(encrypted.hashCode, PdfOpenErrorKind.encrypted.hashCode);
      expect('$encrypted', 'PdfOpenException(encrypted)');
    });
  });

  group('the output models', () {
    test('compare by value', () {
      const block = PdfTextBlock(
        rect: Rect.fromLTRB(1, 2, 3, 4),
        text: 'a',
        color: Color(0xFF000000),
        background: Color(0xFFFFFFFF),
        direction: TextDirection.ltr,
      );
      const same = PdfTextBlock(
        rect: Rect.fromLTRB(1, 2, 3, 4),
        text: 'a',
        color: Color(0xFF000000),
        background: Color(0xFFFFFFFF),
        direction: TextDirection.ltr,
      );
      expect(block, same);
      expect(block.hashCode, same.hashCode);
      expect('$block', startsWith('PdfTextBlock(a, '));
      const page = PdfOutputPage(
        sourcePage: 0,
        size: Size(10, 10),
        blocks: [block],
      );
      expect(
        page,
        const PdfOutputPage(sourcePage: 0, size: Size(10, 10), blocks: [same]),
      );
      expect(
        page.hashCode,
        const PdfOutputPage(
          sourcePage: 0,
          size: Size(10, 10),
          blocks: [same],
        ).hashCode,
      );
      expect(
        page,
        isNot(const PdfOutputPage(sourcePage: 0, size: Size(10, 10))),
      );
      expect('$page', 'PdfOutputPage(0, Size(10.0, 10.0), 1 blocks)');
    });
  });
}
