// HTML fragments are deliberately split into adjacent string literals.
// ignore_for_file: missing_whitespace_between_adjacent_strings

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/web_translate/core/html_tokenizer.dart';

String describe(Iterable<HtmlToken> tokens) => tokens
    .map(
      (token) => switch (token) {
        HtmlStartTag(:final name, :final attributes, :final selfClosing) =>
          '<$name${_attributes(attributes)}${selfClosing ? '/' : ''}>',
        HtmlEndTag(:final name) => '</$name>',
        HtmlCharacters(:final text) => text,
      },
    )
    .join('|');

String _attributes(Map<String, String> attributes) =>
    attributes.entries.map((e) => ' ${e.key}=${e.value}').join();

void main() {
  group('tokenizeHtml', () {
    test('splits tags and text and lower-cases names', () {
      expect(
        describe(tokenizeHtml('<P CLASS="a">Hi <B>there</B></P>')),
        '<p class=a>|Hi |<b>|there|</b>|</p>',
      );
    });

    test('parses quoted, unquoted and empty attributes', () {
      final tag =
          tokenizeHtml(
                '<img src=/a.png alt=\'A "b"\' data-x = "1 > 0" hidden '
                'alt="dup">',
              ).single
              as HtmlStartTag;
      expect(tag.attributes, {
        'src': '/a.png',
        'alt': 'A "b"',
        'data-x': '1 > 0',
        'hidden': '',
      });
    });

    test('decodes entities in text and attribute values', () {
      expect(
        describe(tokenizeHtml('<a title="Tom &amp; Jerry">&lt;3&gt;</a>')),
        '<a title=Tom & Jerry>|<3>|</a>',
      );
    });

    test('recognises self-closing tags', () {
      expect(describe(tokenizeHtml('a<br/>b<hr />')), 'a|<br/>|b|<hr/>');
    });

    test('skips comments, doctypes and processing instructions', () {
      expect(
        describe(
          tokenizeHtml(
            '<!DOCTYPE html><?xml version="1.0"?>a<!-- <p>no</p> -->b',
          ),
        ),
        'a|b',
      );
    });

    test('drops an unterminated comment and everything after it', () {
      expect(describe(tokenizeHtml('a<!-- open <p>b</p>')), 'a');
    });

    test('reads CDATA sections as text', () {
      expect(describe(tokenizeHtml('<![CDATA[x < y]]>')), 'x < y');
    });

    test('reads script and style content as raw text', () {
      expect(
        describe(
          tokenizeHtml(
            '<script>if (a<b) { x = "</div>"; }</script>'
            '<style>p > a { }</STYLE >after',
          ),
        ),
        '<script>|if (a<b) { x = "</div>"; }|</script>|'
        '<style>|p > a { }|</style>|after',
      );
    });

    test('does not end raw text at a longer tag name', () {
      expect(
        describe(tokenizeHtml('<script>a</scripts>b</script>c')),
        '<script>|a</scripts>b|</script>|c',
      );
    });

    test('an unclosed script swallows the rest of the document', () {
      expect(
        describe(tokenizeHtml('<script>var a = 1; <p>x</p>')),
        '<script>|var a = 1; <p>x</p>',
      );
    });

    test('decodes entities in title and textarea but not tags', () {
      expect(
        describe(tokenizeHtml('<title>A &amp; <b>B</b></title>')),
        '<title>|A & <b>B</b>|</title>',
      );
    });

    test('an unclosed title is parsed as normal markup', () {
      expect(describe(tokenizeHtml('<title>T<p>x')), '<title>|T|<p>|x');
    });

    test('plaintext swallows the rest', () {
      expect(describe(tokenizeHtml('<plaintext><b>x')), '<plaintext>|<b>x');
    });

    test('keeps stray less-than signs as text', () {
      expect(describe(tokenizeHtml('5 < 6 and a <3 b')), '5 < 6 and a <3 b');
      expect(describe(tokenizeHtml('end <')), 'end <');
    });

    test('ignores </> and treats </ x> as a bogus comment', () {
      expect(describe(tokenizeHtml('a</>b</ x>c')), 'a|b|c');
    });

    test('drops unterminated tags at the end', () {
      expect(describe(tokenizeHtml('text <div class="a')), 'text ');
      expect(describe(tokenizeHtml('text <div class=')), 'text ');
      expect(describe(tokenizeHtml('text </div')), 'text ');
      expect(describe(tokenizeHtml('text </div class="x')), 'text ');
    });

    test('honours quotes in end tags', () {
      expect(describe(tokenizeHtml('</p x="a>b">c')), '</p>|c');
    });

    test('ignores raw text for self-closing script', () {
      expect(
        describe(tokenizeHtml('<script src=a.js />text')),
        '<script src=a.js/>|text',
      );
    });

    test('token toString is readable', () {
      expect(const HtmlStartTag('p').toString(), contains('p'));
      expect(const HtmlEndTag('p').toString(), contains('p'));
      expect(const HtmlCharacters('x').toString(), contains('x'));
    });
  });
}
