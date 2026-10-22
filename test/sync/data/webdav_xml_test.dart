import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/sync/data/webdav_xml.dart';

import '../helpers/webdav_samples.dart';

void main() {
  group('parseXml', () {
    test('resolves prefixes, default namespaces and redeclarations', () {
      final root = parseXml(
        [
          '<a:root xmlns:a="urn:a" xmlns="urn:d">',
          '<child/><a:x xmlns:a="urn:b"><y xmlns=""/></a:x></a:root>',
        ].join(),
      );
      expect(root.namespace, 'urn:a');
      expect(root.name, 'root');
      expect(root.children[0].namespace, 'urn:d');
      expect(root.children[1].namespace, 'urn:b');
      expect(root.children[1].children.single.namespace, isNull);
    });

    test('decodes entities, character references and CDATA', () {
      final root = parseXml(
        [
          '<r a="&amp;&quot;">&lt;&gt;&amp;&apos;&quot;&#65;&#x42;',
          '<![CDATA[<raw>&amp;]]>&unknown;&#xFFFFFFF;</r>',
        ].join(),
      );
      expect(root.text, '<>&\'"AB<raw>&amp;&unknown;&#xFFFFFFF;');
    });

    test('skips declarations, comments, doctypes and processing', () {
      final root = parseXml(
        [
          '<?xml version="1.0"?><!DOCTYPE r [<!ENTITY e "boom">]>',
          '<!-- c --><r><?pi x?>t<!-- inner --></r>',
        ].join(),
      );
      expect(root.name, 'r');
      expect(root.allText, 't');
    });

    test('allText joins the text of descendants', () {
      final root = parseXml('<r>a<b>b<c>c</c></b>d</r>');
      expect(root.allText, 'adbc');
      expect(root.text, 'ad');
    });

    test('accepts single-quoted attributes and spaces in tags', () {
      final root = parseXml("<r  x = 'y' ><e  /></r >");
      expect(root.children.single.name, 'e');
    });

    for (final (name, source) in [
      ('mismatched end tag', '<a></b>'),
      ('unclosed element', '<a><b></b>'),
      ('no root', 'just text'),
      ('unclosed start tag', '<a'),
      ('unclosed end tag', '<a></a'),
      ('unclosed comment', '<a><!-- x</a>'),
      ('unclosed declaration', '<!DOCTYPE a [ <a/>'),
      ('unquoted attribute', '<a b=c/>'),
      ('attribute without value', '<a b/>'),
      ('unclosed attribute', '<a b="c/>'),
      ('empty tag name', '< />'),
      ('attribute at the end', '<a b='),
      ('stray end tag', '</a>'),
    ]) {
      test('throws for $name', () {
        expect(() => parseXml(source), throwsFormatException);
      });
    }

    test('keeps the first root of several', () {
      expect(parseXml('<a/><b/>').name, 'a');
      expect(parseXml('<a></a><b/>').name, 'a');
    });
  });

  group('parseMultistatus', () {
    test('reads Nextcloud folders (quoted ETag, 404 propstat)', () {
      final folder = parseMultistatus(nextcloudFolder).single;
      expect(folder.href, '/remote.php/dav/files/alice/Mozhi/');
      expect(folder.isCollection, isTrue);
      expect(folder.hasResourceType, isTrue);
      expect(folder.etag, '"6436d084d4805"');
      expect(folder.contentLength, isNull);
      expect(folder.status, isNull);
    });

    test('reads Nextcloud files', () {
      final file = parseMultistatus(nextcloudFile).single;
      expect(file.isCollection, isFalse);
      expect(file.hasResourceType, isTrue);
      expect(file.etag, '"8f3c1e2a"');
      expect(file.contentLength, 2048);
    });

    test('reads Apache mod_dav (lp1 namespace)', () {
      final folder = parseMultistatus(apacheFolder).single;
      expect(folder.href, '/webdav/Mozhi/');
      expect(folder.isCollection, isTrue);
      expect(folder.etag, '"1000-5f2b1c3d4e5f6"');
    });

    test('reads rclone (x/net/webdav)', () {
      final folder = parseMultistatus(rcloneFolder).single;
      expect(folder.isCollection, isTrue);
      expect(folder.etag, isNull);
    });

    test('reads a default DAV: namespace and CDATA', () {
      final folder = parseMultistatus(defaultNamespaceFolder).single;
      expect(folder.href, 'https://dav.example.org/Mozhi/');
      expect(folder.isCollection, isTrue);
      expect(folder.etag, '"abc"');
    });

    test('tells a missing resourcetype from an empty one', () {
      final folder = parseMultistatus(noResourceTypeFolder).single;
      expect(folder.hasResourceType, isFalse);
      expect(folder.isCollection, isFalse);
    });

    test('reads a response-level status', () {
      expect(parseMultistatus(missingResponse).single.status, 404);
    });

    test('accepts elements without a namespace and without status', () {
      final resources = parseMultistatus(
        [
          '<multistatus><response><href>/a/</href><propstat><prop>',
          '<resourcetype><collection/></resourcetype>',
          '<getcontentlength>x</getcontentlength><getetag> </getetag>',
          '</prop></propstat></response>',
          '<response><href> </href></response></multistatus>',
        ].join(),
      );
      expect(resources, hasLength(1));
      expect(resources.single.isCollection, isTrue);
      expect(resources.single.contentLength, isNull);
      expect(resources.single.etag, isNull);
    });

    test('ignores elements of other namespaces', () {
      final resources = parseMultistatus(
        [
          '<d:multistatus xmlns:d="DAV:" xmlns:x="urn:x"><d:response>',
          '<d:href>/a</d:href><d:propstat><d:prop>',
          '<x:getetag>"no"</x:getetag></d:prop>',
          '<d:status>HTTP/1.1 200 OK</d:status></d:propstat>',
          '</d:response></d:multistatus>',
        ].join(),
      );
      expect(resources.single.etag, isNull);
    });

    test('throws for other documents', () {
      expect(
        () => parseMultistatus(nextcloudNotAuthenticated),
        throwsFormatException,
      );
      expect(() => parseMultistatus(htmlPage), throwsFormatException);
      expect(() => parseMultistatus('{"error": 1}'), throwsFormatException);
    });
  });

  test('parseDavStatus reads status lines', () {
    expect(parseDavStatus('HTTP/1.1 200 OK'), 200);
    expect(parseDavStatus('  HTTP/2 404 Not Found'), 404);
    expect(parseDavStatus('nonsense'), isNull);
    expect(parseDavStatus(null), isNull);
  });
}
