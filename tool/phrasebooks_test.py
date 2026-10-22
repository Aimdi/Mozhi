#!/usr/bin/env python3
"""Tests of tool/phrasebooks.py (stdlib unittest):

  python3 tool/phrasebooks_test.py

The fixtures in tool/phrasebooks_fixtures/ are hand-written in the shape of
Wikivoyage's phrasebook articles (wikivoyage.org isn't reachable from the
development machines; CI fetches the real pages).
"""

import contextlib
import gzip
import hashlib
import io
import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import phrasebooks  # noqa: E402

FIXTURES = os.path.join(HERE, 'phrasebooks_fixtures')


def fixture(name):
    with open(os.path.join(FIXTURES, name), encoding='utf-8') as file:
        return file.read()


def portuguese_pack(**options):
    return phrasebooks.build_pack(
        fixture('portuguese_phrasebook.wikitext'), language='pt',
        title='Portuguese phrasebook', revision=4567890,
        retrieved='2026-10-22', **options)


class CleanTest(unittest.TestCase):
    def test_markup(self):
        self.assertEqual(
            phrasebooks.clean("'''''Olá''''' [[Lisbon|Lisboa]] [[Porto]]"),
            'Olá Lisboa Porto')
        self.assertEqual(
            phrasebooks.clean('a<ref name="x">note</ref> b<ref name="y"/> '
                              '<!-- hidden --> c&nbsp;d &amp; e'),
            'a b c d & e')
        self.assertEqual(phrasebooks.clean('one<br/>two <small>x</small>'),
                         'one two x')
        self.assertEqual(
            phrasebooks.clean('[https://example.org a link] here'),
            'a link here')

    def test_templates(self):
        self.assertEqual(phrasebooks.clean('{{lang|pt|Olá}} there'),
                         'Olá there')
        self.assertEqual(phrasebooks.clean('{{IPA|oˈla}}Olá'), 'Olá')
        self.assertEqual(phrasebooks.clean('{{a|{{b|c}}|d}}x'), 'x')
        self.assertEqual(phrasebooks.clean('{{nowrap|a b}}'), 'a b')


class SplitForeignTest(unittest.TestCase):
    def test_italic_pronunciation(self):
        self.assertEqual(phrasebooks.split_foreign("Olá. (''oh-LAH'')"),
                         ('Olá.', 'oh-LAH'))
        self.assertEqual(
            phrasebooks.split_foreign(
                "Bem, obrigado (male). (''bayñ'')"),
            ('Bem, obrigado (male).', 'bayñ'))

    def test_plain_romanization_after_another_script(self):
        self.assertEqual(phrasebooks.split_foreign('Спасибо (spah-SEE-bah)'),
                         ('Спасибо', 'spah-SEE-bah'))
        # A note in a Latin-script language is not a pronunciation.
        self.assertEqual(phrasebooks.split_foreign('Obrigado (male)'),
                         ('Obrigado (male)', ''))
        # Nor is a group in the same script.
        self.assertEqual(phrasebooks.split_foreign('一 (いち)'),
                         ('一 (いち)', ''))

    def test_no_pronunciation(self):
        self.assertEqual(phrasebooks.split_foreign('Sim.'), ('Sim.', ''))


class ParseTest(unittest.TestCase):
    def setUp(self):
        self.sections = phrasebooks.parse_wikitext(
            fixture('portuguese_phrasebook.wikitext'))
        self.titles = [title for title, _ in self.sections]

    def test_sections_of_the_phrase_list_in_order(self):
        self.assertEqual(self.titles, [
            'Basics', 'Problems', 'Numbers', 'Time', 'Clock time',
            'Directions', 'Eating', 'Bars'])

    def test_guides_and_reading_lists_are_skipped(self):
        phrases = [p for _, items in self.sections for p in items]
        self.assertNotIn('a', [english for english, _, _ in phrases])
        self.assertNotIn('Grammar', [english for english, _, _ in phrases])

    def test_phrase_shapes(self):
        basics = dict(self.sections)['Basics']
        self.assertEqual(basics[0], ('Hello.', 'Olá.', 'oh-LAH'))
        # Markup in the English part.
        self.assertIn(('Hello. (informal)', 'Oi.', 'oy'), basics)
        # The foreign part on the next line.
        self.assertIn(
            ('What is your name?', 'Como se chama?', 'KOH-moo seh SHAH-mah?'),
            basics)
        problems = dict(self.sections)['Problems']
        # Links.
        self.assertIn(
            ('Call the police!', 'Chame a polícia!',
             'SHAH-meh ah poo-LEE-see-ah!'), problems)
        clock = dict(self.sections)['Clock time']
        # A time is not where the line splits.
        self.assertEqual(clock[1][0], "It's 10:30.")
        directions = dict(self.sections)['Directions']
        # A bullet line and the template.
        self.assertIn(('straight ahead', 'em frente', 'ayñ FREHN-teh'),
                      directions)
        self.assertIn(('north', 'norte', 'NOHR-teh'), directions)

    def test_without_a_phrase_list_heading_everything_is_read(self):
        sections = phrasebooks.parse_wikitext(
            '===Basics===\n; Yes : Sim\n; Odd line without a colon\n'
            'Some prose.\n: an orphan definition\n')
        self.assertEqual(sections, [('Basics', [('Yes', 'Sim', '')])])
        self.assertEqual(
            phrasebooks.parse_wikitext('; Yes : Sim'), [('', [('Yes', 'Sim',
                                                                '')])])

    def test_limits(self):
        text = '==Phrase list==\n===A===\n' + '\n'.join(
            f'; w{i} : p{i}' for i in range(10))
        sections = phrasebooks.parse_wikitext(text, max_phrases=3)
        self.assertEqual(len(sections[0][1]), 3)
        long = '==Phrase list==\n===A===\n; ' + 'x' * 400 + ' : y\n; a : b'
        self.assertEqual(phrasebooks.parse_wikitext(long),
                         [('A', [('a', 'b', '')])])

    def test_japanese(self):
        sections = dict(phrasebooks.parse_wikitext(
            fixture('japanese_phrasebook.wikitext')))
        self.assertEqual(sections['Basics'][2],
                         ('Thank you.', 'ありがとう。', 'arigatō'))
        self.assertEqual(sections['Numbers'][0], ('1', '一 (いち)', 'ichi'))
        self.assertEqual(sections['Eating'][0][2], 'menyū o kudasai')


class PackTest(unittest.TestCase):
    def test_fields_and_attribution(self):
        pack = portuguese_pack()
        self.assertEqual(pack['format'], 'mozhi-phrasebook')
        self.assertEqual(pack['formatVersion'], 1)
        self.assertEqual(pack['id'], 'pt')
        self.assertEqual(pack['language'], 'pt')
        self.assertEqual(pack['baseLanguage'], 'en')
        self.assertEqual(pack['name'], 'Portuguese')
        self.assertEqual(pack['source'], 'Wikivoyage')
        self.assertEqual(pack['sourceUrl'],
                         'https://en.wikivoyage.org/wiki/Portuguese_phrasebook')
        self.assertEqual(
            pack['revisionUrl'],
            'https://en.wikivoyage.org/w/index.php?title=Portuguese_phrasebook'
            '&oldid=4567890')
        self.assertTrue(pack['authorsUrl'].endswith('&action=history'))
        self.assertEqual(pack['license'], 'CC BY-SA 4.0')
        self.assertIn('Wikivoyage contributors', pack['attribution'])
        self.assertIn('4567890', pack['attribution'])
        self.assertEqual(pack['retrieved'], '2026-10-22')

    def test_phrases_have_stable_ids_and_no_duplicates(self):
        pack = portuguese_pack()
        basics = pack['sections'][0]['phrases']
        self.assertEqual(basics[0], {
            'id': phrasebooks.phrase_id('Hello.', 'Olá.'),
            'text': 'Hello.', 'translation': 'Olá.',
            'pronunciation': 'oh-LAH'})
        # "Hello." twice: once.
        self.assertEqual([p['text'] for p in basics].count('Hello.'), 1)
        ids = [p['id'] for s in pack['sections'] for p in s['phrases']]
        self.assertEqual(len(ids), len(set(ids)))
        self.assertTrue(all(len(i) == 12 for i in ids))

    def test_other_base_language_and_names(self):
        pack = portuguese_pack(base_language='de', name='Portugiesisch')
        self.assertEqual(pack['id'], 'pt-de')
        self.assertEqual(pack['name'], 'Portugiesisch')
        with self.assertRaises(ValueError):
            portuguese_pack(pack_id='Not valid')

    def test_unknown_language_name_comes_from_the_title(self):
        pack = phrasebooks.build_pack(
            '; Hi : Bula', language='fj', title='Fijian phrasebook',
            revision=0, retrieved='')
        self.assertEqual(pack['name'], 'Fijian')
        self.assertEqual(pack['revisionUrl'],
                         'https://en.wikivoyage.org/wiki/Fijian_phrasebook')

    def test_no_phrases(self):
        with self.assertRaises(ValueError):
            phrasebooks.build_pack('==Phrase list==\nNothing.', language='pt',
                                   title='X', revision=1, retrieved='')

    def test_bytes_are_reproducible_gzip_json(self):
        data = phrasebooks.pack_bytes(portuguese_pack())
        self.assertEqual(data, phrasebooks.pack_bytes(portuguese_pack()))
        self.assertEqual(data[:2], b'\x1f\x8b')
        self.assertEqual(json.loads(gzip.decompress(data)),
                         portuguese_pack())
        stats = phrasebooks.stats(portuguese_pack(), data)
        self.assertEqual(stats['sha256'], hashlib.sha256(data).hexdigest())
        self.assertEqual(stats['phrases'], 39)
        self.assertEqual(stats['sections'], 8)
        self.assertEqual(stats['pronunciations'], 39)

    def test_too_large(self):
        old = phrasebooks.MAX_PACK_BYTES
        phrasebooks.MAX_PACK_BYTES = 10
        try:
            with self.assertRaises(ValueError):
                phrasebooks.pack_bytes(portuguese_pack())
        finally:
            phrasebooks.MAX_PACK_BYTES = old


class AppFixtureTest(unittest.TestCase):
    def test_the_apps_fixture_is_this_tools_output(self):
        # test/phrasebook/fixtures/pt_pack.json is what the app's tests
        # read (StarterPhrasebook.fromJson); rebuild it when this fails:
        #   python3 tool/phrasebooks.py build ... (see the file's history)
        path = os.path.join(HERE, '..', 'test', 'phrasebook', 'fixtures',
                            'pt_pack.json')
        with open(path, encoding='utf-8') as file:
            self.assertEqual(json.load(file), portuguese_pack())


class ApiTest(unittest.TestCase):
    def test_url(self):
        url = phrasebooks.api_url('Portuguese phrasebook')
        self.assertIn('titles=Portuguese+phrasebook', url)
        self.assertIn('rvslots=main', url)
        self.assertIn('revids=42', phrasebooks.api_url('X', revision=42))

    def test_response(self):
        page = phrasebooks.parse_api_response(
            json.loads(fixture('api_response.json')))
        self.assertEqual(page['title'], 'Portuguese phrasebook')
        self.assertEqual(page['revision'], 4567890)
        self.assertIn('Olá', page['wikitext'])
        legacy = {'query': {'pages': [{'title': 'T', 'revisions': [
            {'revid': 1, 'content': 'x'}]}]}}
        self.assertEqual(phrasebooks.parse_api_response(legacy)['wikitext'],
                         'x')
        for missing in ({}, {'query': {'pages': [{'missing': True}]}},
                        {'query': {'pages': [{'revisions': [{}]}]}}):
            with self.assertRaises(ValueError):
                phrasebooks.parse_api_response(missing)

    def test_fetch(self):
        body = fixture('api_response.json').encode('utf-8')
        requests = []

        @contextlib.contextmanager
        def opener(request, timeout):
            requests.append(request)
            yield io.BytesIO(body)

        page = phrasebooks.fetch('pt', opener=opener)
        self.assertEqual(page['revision'], 4567890)
        self.assertIn('MozhiPhrasebookBuilder',
                      requests[0].get_header('User-agent'))
        self.assertEqual(
            phrasebooks.fetch('pt', revision=4567890, opener=opener)['title'],
            'Portuguese phrasebook')
        with self.assertRaises(ValueError):
            phrasebooks.fetch('pt', revision=1, opener=opener)
        with self.assertRaises(ValueError):
            phrasebooks.fetch('es', opener=opener)


class CatalogTest(unittest.TestCase):
    def test_catalog_and_dart(self):
        with tempfile.TemporaryDirectory() as tmp:
            pt = os.path.join(tmp, 'pt.json.gz')
            ja = os.path.join(tmp, 'ja.json.gz')
            with open(pt, 'wb') as file:
                file.write(phrasebooks.pack_bytes(portuguese_pack()))
            with open(ja, 'wb') as file:
                file.write(phrasebooks.pack_bytes(phrasebooks.build_pack(
                    fixture('japanese_phrasebook.wikitext'), language='ja',
                    title='Japanese phrasebook', revision=7,
                    retrieved='2026-10-22')))
            result = phrasebooks.catalog(
                [pt, ja], 'phrasebooks-2026-10-22',
                'https://example.org/download/phrasebooks-2026-10-22/',
                source='https://example.org/tag')
            self.assertEqual(result['schemaVersion'], 1)
            self.assertEqual(result['release'], 'phrasebooks-2026-10-22')
            self.assertEqual([p['id'] for p in result['packs']], ['ja', 'pt'])
            entry = result['packs'][1]
            with open(pt, 'rb') as file:
                data = file.read()
            self.assertEqual(entry['size'], len(data))
            self.assertEqual(entry['sha256'], hashlib.sha256(data).hexdigest())
            self.assertEqual(
                entry['url'],
                'https://example.org/download/phrasebooks-2026-10-22/'
                'pt.json.gz')
            self.assertEqual(entry['file'], 'pt.json.gz')
            self.assertEqual(entry['phrases'], 39)
            self.assertEqual(entry['revision'], 4567890)

            dart = phrasebooks.dart_catalog(result)
            self.assertIn("const starterCatalogJson = '''", dart)
            self.assertIn('"pt.json.gz"', dart)
            self.assertNotIn('$', dart.replace('\\$', ''))

            wrong = os.path.join(tmp, 'other.json.gz')
            os.rename(pt, wrong)
            with self.assertRaises(ValueError):
                phrasebooks.catalog([wrong], 'r', 'https://x')

    def test_dart_refuses_triple_quotes(self):
        with self.assertRaises(ValueError):
            phrasebooks.dart_catalog({'packs': ["'''"]})

    def test_read_pack_refuses_other_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, 'x.json.gz')
            with open(path, 'wb') as file:
                file.write(gzip.compress(b'{"format": "other"}'))
            with self.assertRaises(ValueError):
                phrasebooks.read_pack(path)

    def test_duplicate_ids(self):
        with tempfile.TemporaryDirectory() as tmp:
            first = os.path.join(tmp, 'a', 'pt.json.gz')
            second = os.path.join(tmp, 'b', 'pt.json.gz')
            for path in (first, second):
                os.makedirs(os.path.dirname(path))
                with open(path, 'wb') as file:
                    file.write(phrasebooks.pack_bytes(portuguese_pack()))
            with self.assertRaises(ValueError):
                phrasebooks.catalog([first, second], 'r', 'https://x')


class CommandLineTest(unittest.TestCase):
    def run_main(self, *args):
        out = io.StringIO()
        err = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = phrasebooks.main(list(args))
        return code, out.getvalue(), err.getvalue()

    def test_build_catalog_dart_dump(self):
        with tempfile.TemporaryDirectory() as tmp:
            page = os.path.join(tmp, 'pt.page.json')
            with open(page, 'w', encoding='utf-8') as file:
                json.dump({
                    'title': 'Portuguese phrasebook', 'revision': 4567890,
                    'timestamp': '2026-10-01T12:00:00Z',
                    'wikitext': fixture('portuguese_phrasebook.wikitext'),
                }, file)
            pack = os.path.join(tmp, 'pt.json.gz')
            stats = os.path.join(tmp, 'pt.stats.json')
            code, _, err = self.run_main(
                'build', page, '--language', 'pt', '--output', pack,
                '--retrieved', '2026-10-22', '--stats', stats)
            self.assertEqual(code, 0)
            self.assertIn('39 phrases', err)
            with open(stats, encoding='utf-8') as file:
                self.assertEqual(json.load(file)['phrases'], 39)

            wikitext = os.path.join(tmp, 'ja.wikitext')
            with open(wikitext, 'w', encoding='utf-8') as file:
                file.write(fixture('japanese_phrasebook.wikitext'))
            ja = os.path.join(tmp, 'ja.json.gz')
            self.assertEqual(self.run_main(
                'build', wikitext, '--language', 'ja', '--title',
                'Japanese phrasebook', '--revision', '7', '--output', ja)[0], 0)
            with self.assertRaises(SystemExit):
                self.run_main('build', wikitext, '--language', 'ja',
                              '--output', ja)

            code, out, _ = self.run_main(
                'catalog', pack, ja, '--release', 'phrasebooks-2026-10-22',
                '--base-url', 'https://example.org/d', '--source',
                'https://example.org/t')
            catalog_path = os.path.join(tmp, 'catalog.json')
            with open(catalog_path, 'w', encoding='utf-8') as file:
                file.write(out)
            self.assertEqual(len(json.loads(out)['packs']), 2)
            _, dart, _ = self.run_main('dart', catalog_path)
            self.assertIn('starterCatalogJson', dart)
            _, dump, _ = self.run_main('dump', pack)
            self.assertIn('== Basics', dump)
            self.assertIn('Hello. : Olá. (oh-LAH)', dump)
            _, pages, _ = self.run_main('pages')
            self.assertIn('pt\tPortuguese\thttps://en.wikivoyage.org/wiki/'
                          'Portuguese_phrasebook', pages)

    def test_fetch_unknown_language(self):
        with self.assertRaises(SystemExit):
            self.run_main('fetch', 'xx', '--output', os.devnull)


if __name__ == '__main__':
    unittest.main()
