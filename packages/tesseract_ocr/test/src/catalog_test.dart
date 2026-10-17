import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tesseract_ocr/tesseract_ocr.dart';

import '../helpers/native_library.dart';

Map<String, Object?> _language({
  String code = 'deu',
  String name = 'German',
  List<Object?> languages = const ['de'],
  String? url,
  Object? size = 1525436,
  Object? sha256 =
      '0000000000000000000000000000000000000000000000000000000000000001',
}) => {
  'code': code,
  'name': name,
  'languages': languages,
  'url':
      url ??
      'https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/'
          '$tessdataCommit/$code.traineddata',
  'size': size,
  'sha256': sha256,
};

Map<String, Object?> _catalog(List<Map<String, Object?>> languages) => {
  'schemaVersion': 1,
  'source': 'https://github.com/tesseract-ocr/tessdata_fast',
  'commit': tessdataCommit,
  'languages': languages,
};

void main() {
  final bundled = TessdataCatalog.parse(
    File('assets/catalog.json').readAsStringSync(),
  );

  group('bundled catalog', () {
    test('lists 110 languages pinned to one tessdata_fast commit', () {
      expect(bundled.languages, hasLength(110));
      expect(bundled.commit, tessdataCommit);
      expect(bundled.source, 'https://github.com/tesseract-ocr/tessdata_fast');
      for (final language in bundled.languages) {
        expect(
          language.url.toString(),
          'https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/'
          '$tessdataCommit/${language.code}.traineddata',
        );
        expect(language.fileName, '${language.code}.traineddata');
        expect(language.size, greaterThan(100000));
      }
    });

    test('is sorted by code and has no OSD, vertical or old data', () {
      final codes = [for (final language in bundled.languages) language.code];
      expect(codes, [...codes]..sort());
      expect(codes, isNot(contains('osd')));
      expect(codes, isNot(contains('equ')));
      expect(codes.where((code) => code.endsWith('_vert')), isEmpty);
      expect(codes.where((code) => code.endsWith('_old')), isEmpty);
    });

    test('is ~311 MB in total, German ~1.5 MB', () {
      expect(bundled.totalSize, 310823071);
      expect(bundled.byCode('deu')!.size, 1525436);
      expect(bundled.byCode('eng')!.size, 4113088);
      expect(
        bundled.byCode('eng')!.sha256,
        '7d4322bd2a7749724879683fc3912cb542f19906c83bcc1a52132556427170b2',
      );
    });

    test('round-trips through JSON', () {
      final again = TessdataCatalog.fromJson(
        jsonDecode(jsonEncode(bundled.toJson())) as Map<String, Object?>,
      );
      expect(again.languages, bundled.languages);
      expect(again.commit, bundled.commit);
    });

    test('loads from the asset bundle', () async {
      final catalog = await loadBundledTessdataCatalog(bundle: _FileBundle());
      expect(catalog.languages, bundled.languages);
    });
  });

  group('forAppLanguage', () {
    String? code(String app) => bundled.forAppLanguage(app)?.code;

    test('maps the app catalogue codes', () {
      expect(code('en'), 'eng');
      expect(code('de'), 'deu');
      expect(code('ja'), 'jpn');
      expect(code('ko'), 'kor');
      expect(code('ar'), 'ara');
      expect(code('hi'), 'hin');
      expect(code('ru'), 'rus');
      expect(code('uk'), 'ukr');
      expect(code('ta'), 'tam');
      expect(code('tl'), 'fil');
      expect(code('fa-AF'), 'fas');
      expect(code('nn'), 'nor');
      expect(code('ku'), 'kmr');
    });

    test('maps Chinese by script or region', () {
      expect(code('zh-CN'), 'chi_sim');
      expect(code('zh'), 'chi_sim');
      expect(code('zh-Hans'), 'chi_sim');
      expect(code('zh_SG'), 'chi_sim');
      expect(code('wuu'), 'chi_sim');
      expect(code('zh-TW'), 'chi_tra');
      expect(code('zh-Hant'), 'chi_tra');
      expect(code('zh-HK'), 'chi_tra');
      expect(code('zh-Hant-TW'), 'chi_tra');
      expect(code('yue'), 'chi_tra');
      expect(code('lzh'), 'chi_tra');
    });

    test('drops regions, ignoring case and underscores', () {
      expect(code('en-GB'), 'eng');
      expect(code('EN_us'), 'eng');
      expect(code('pt-BR'), 'por');
      expect(code('es-419'), 'spa');
      expect(code('ar-EG'), 'ara');
      expect(code(' de-CH '), 'deu');
    });

    test('matches a script subtag only to data of that script', () {
      expect(code('sr'), 'srp');
      expect(code('sr-Cyrl'), 'srp');
      expect(code('sr-Latn'), 'srp_latn');
      expect(code('sr-Latn-RS'), 'srp_latn');
      expect(code('pa'), 'pan');
      expect(code('pa-Arab'), isNull);
      expect(code('ms'), 'msa');
      expect(code('ms-Arab'), isNull);
      expect(code('uz-Latn'), 'uzb');
      expect(code('uz-Cyrl'), isNull);
    });

    test('resolves legacy and alternative codes', () {
      expect(code('iw'), 'heb');
      expect(code('nb'), 'nor');
      expect(code('fil'), 'fil');
      expect(code('in'), 'ind');
      expect(code('ji'), 'yid');
      expect(code('jw'), 'jav');
      expect(code('kmr'), 'kmr');
      expect(code('prs'), 'fas');
    });

    test('is null for languages without data', () {
      expect(code('auto'), isNull);
      expect(code(''), isNull);
      expect(code('xh'), isNull);
      expect(code('ckb'), isNull);
      expect(code('ber-Latn'), isNull);
    });
  });

  group('TessdataCatalog.fromJson', () {
    TessdataCatalog parse(Map<String, Object?> json) =>
        TessdataCatalog.parse(jsonEncode(json));

    test('parses a minimal catalog', () {
      final catalog = parse(_catalog([_language()]));
      final german = catalog.byCode('deu')!;
      expect(german.name, 'German');
      expect(german.languages, ['de']);
      expect(german.toString(), 'TessdataLanguage(deu)');
      expect(catalog.byCode('eng'), isNull);
      expect(catalog.forAppLanguage('de'), german);
      expect(german, TessdataLanguage.fromJson(_language()));
      expect(german.hashCode, TessdataLanguage.fromJson(_language()).hashCode);
    });

    test('rejects invalid catalogs', () {
      void rejects(Object? json) => expect(
        () => TessdataCatalog.parse(jsonEncode(json)),
        throwsFormatException,
      );
      rejects([]);
      rejects({..._catalog([]), 'schemaVersion': 2});
      rejects({'schemaVersion': 1});
      rejects(_catalog([])..['languages'] = ['x']);
      rejects(_catalog([_language(), _language()]));
      rejects(
        _catalog([
          _language(),
          _language(code: 'eng', languages: ['DE']),
        ]),
      );
    });

    test('rejects invalid languages', () {
      void rejects(Map<String, Object?> language) => expect(
        () => TessdataCatalog.fromJson(_catalog([language])),
        throwsFormatException,
      );
      rejects(_language(code: '../deu'));
      rejects(_language(code: 'de'));
      rejects(_language(code: 'chi_simplified'));
      rejects(_language(name: ''));
      rejects(_language(languages: []));
      rejects(_language(languages: [1]));
      rejects(_language(languages: ['not a code']));
      rejects(_language(url: 'http://example.org/deu.traineddata'));
      rejects(_language(url: 'https:///deu.traineddata'));
      rejects(_language(url: 'https://example.org/eng.traineddata'));
      rejects(_language(size: 0));
      rejects(_language(size: '1'));
      rejects(_language(sha256: 'ABC'));
      rejects(_language(sha256: 1));
    });
  });

  test('isTesseractCode', () {
    expect(isTesseractCode('eng'), isTrue);
    expect(isTesseractCode('chi_sim'), isTrue);
    expect(isTesseractCode('srp_latn'), isTrue);
    for (final code in ['', 'en', 'ENG', 'eng+deu', '../eng', 'chi_', 'eng ']) {
      expect(isTesseractCode(code), isFalse, reason: code);
    }
  });
}

class _FileBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    expect(key, TessdataCatalog.assetKey);
    final bytes = File('assets/catalog.json').readAsBytesSync();
    return ByteData.sublistView(bytes);
  }
}
