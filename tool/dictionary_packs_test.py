#!/usr/bin/env python3
"""Tests for tool/dictionary_packs.py, on the hand-written wiktextract
extracts in tool/dictionary_packs_fixtures/.

  python3 tool/dictionary_packs_test.py            # run the tests
  python3 tool/dictionary_packs_test.py --update   # rewrite the Dart fixture

The Dart reader's tests read packages/translation_repository/test/fixtures/
dictionary_packs/en.mzd, a pack this tool built from kaikki_en.jsonl; the
cross-check below fails when the tool would now build different content.
"""

import contextlib
import gzip
import hashlib
import io
import json
import os
import struct
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import dictionary_packs as packs  # noqa: E402

FIXTURES = os.path.join(HERE, 'dictionary_packs_fixtures')
EN_JSONL = os.path.join(FIXTURES, 'kaikki_en.jsonl')
ES_JSONL = os.path.join(FIXTURES, 'kaikki_es.jsonl')
DART_FIXTURE = os.path.join(
    os.path.dirname(HERE), 'packages', 'translation_repository', 'test',
    'fixtures', 'dictionary_packs', 'en.mzd')
SNAPSHOT = '2026-10-01'


def build_en(**kwargs):
    entries = packs.collect(packs.read_jsonl(EN_JSONL), packs.Options())
    used = sorted({code for entry, _ in entries for code in entry.get('t', {})})
    return packs.write_pack(entries, 'en', name='English', snapshot=SNAPSHOT,
                            targets=used, **kwargs)


def content(pack):
    """What a pack holds, without its layout."""
    meta = {k: v for k, v in pack.meta.items()
            if k not in ('layout', 'dataLength', 'sha256')}
    return meta, list(pack.keys()), list(pack.entries())


class FoldTest(unittest.TestCase):
    def test_case_and_accents(self):
        self.assertEqual(packs.fold('Café'), 'cafe')
        self.assertEqual(packs.fold('NAÏVE'), 'naive')
        self.assertEqual(packs.fold('Straße'), 'strasse')
        self.assertEqual(packs.fold('Ångström'), 'angstrom')

    def test_keeps_other_scripts(self):
        for word in ('한국어', 'हिंदी', 'が', 'чай', '家'):
            self.assertEqual(packs.fold(word), packs.fold(word))
            self.assertEqual(len(packs.fold(word)), len(word), word)
        self.assertEqual(packs.fold('Чай'), 'чаи')  # й folds like any accent

    def test_apostrophes_and_spaces(self):
        self.assertEqual(packs.fold('don’t'), "don't")
        self.assertEqual(packs.fold('  ice\u00a0\tcream  '), 'ice cream')
        self.assertEqual(packs.fold('cafe\u0301'), 'cafe')

    def test_table_covers_the_base_letters(self):
        table = packs.fold_table(['café'])
        self.assertEqual(packs.fold('CAFE', table), 'cafe')
        self.assertEqual(packs.fold('Cafe', table), 'cafe')

    def test_table_folds_like_the_builder(self):
        words = ['Café', 'naïve', 'Straße', 'Ärger', 'どう']
        table = packs.fold_table(words)
        for word in words + ['CAFÉ', 'cafe\u0301', 'ÄRGER']:
            self.assertEqual(packs.fold(word, table), packs.fold(word), word)
        self.assertNotIn('a', table)
        self.assertEqual(table['\u0301'], '')


class TrimTest(unittest.TestCase):
    def setUp(self):
        with open(EN_JSONL, encoding='utf-8') as lines:
            self.raw = [json.loads(line) for line in lines
                        if line.startswith('{"word": "') and line.endswith('}\n')]
        self.options = packs.Options()

    def trimmed(self, word, pos):
        raw = next(r for r in self.raw if r['word'] == word and r['pos'] == pos)
        return packs.trim_entry(raw, self.options)

    def test_keeps_what_the_app_shows(self):
        entry, forms = self.trimmed('house', 'noun')
        self.assertEqual(entry['w'], 'house')
        self.assertEqual(entry['p'], 'noun')
        self.assertEqual(entry['i'], 'haʊs')
        self.assertEqual([s['g'] for s in entry['s']], [
            'A structure built or serving as an abode of human beings.',
            'A dynasty; members of the same lineage.',
            'The audience for a live theatrical performance.',
        ])
        self.assertEqual(entry['s'][2]['q'], 'countable, informal')
        # Usage examples before quotations.
        self.assertEqual(entry['s'][0]['x'][0],
                         ["This is my house and my family's ancestral home."])
        self.assertEqual(entry['y'], ['domicile', 'home', 'dwelling'])
        self.assertEqual(entry['r'], ['household', 'housekeeper', 'lighthouse'])
        self.assertTrue(entry['e'].startswith('From Middle English hous'))
        self.assertEqual(forms, ['houses'])

    def test_translations_by_sense_and_target(self):
        entry, _ = self.trimmed('house', 'noun')
        self.assertEqual(entry['t']['de'], [['Haus', 0], ['Dynastie', 1]])
        self.assertEqual(entry['t']['zh'], [['房子', 0]])  # cmn -> zh
        self.assertNotIn('tlh', entry['t'])
        entry, _ = self.trimmed('bank', 'noun')
        self.assertEqual(entry['t']['de'], [['Bank', 0], ['Ufer', 1]])
        self.assertEqual(entry['t']['no'], [['bank', 0]])  # nb -> no

    def test_limits(self):
        options = packs.Options(max_senses=1, max_examples=0, max_words=1,
                                max_translations=1, max_forms=1,
                                max_etymology_chars=20, targets=['de'])
        raw = next(r for r in self.raw if r['word'] == 'house')
        entry, forms = packs.trim_entry(raw, options)
        self.assertEqual(len(entry['s']), 1)
        self.assertNotIn('x', entry['s'][0])
        self.assertEqual(entry['y'], ['domicile'])
        # One per sense; Dynastie's sense was dropped: the whole entry's.
        self.assertEqual(entry['t'], {'de': [['Haus', 0], ['Dynastie', -1]]})
        self.assertEqual(len(entry['e']), 20)
        self.assertTrue(entry['e'].endswith('…'))
        self.assertEqual(forms, ['houses'])

    def test_drops_entries_without_glosses(self):
        self.assertIsNone(self.trimmed('kerfuffle', 'noun'))
        self.assertIsNone(packs.trim_entry({'word': '', 'senses': [
            {'glosses': ['x']}]}, self.options))
        self.assertIsNone(packs.trim_entry('not an entry', self.options))
        self.assertIsNone(packs.trim_entry({'word': 'x' * 101, 'senses': [
            {'glosses': ['x']}]}, self.options))

    def test_form_of(self):
        entry, _ = self.trimmed('went', 'verb')
        self.assertTrue(packs.is_form_of(entry))
        self.assertEqual(entry['s'][0], {'g': 'simple past of go',
                                         'q': 'past', 'o': 'go'})
        entry, _ = self.trimmed('went', 'noun')
        self.assertFalse(packs.is_form_of(entry))


class CollectTest(unittest.TestCase):
    def test_form_of_entries_become_forms(self):
        entries = packs.collect(packs.read_jsonl(EN_JSONL), packs.Options())
        words = [(entry['w'], entry.get('p')) for entry, _ in entries]
        self.assertNotIn(('went', 'verb'), words)
        self.assertNotIn(('gone', 'verb'), words)
        self.assertNotIn(('cafe', 'noun'), words)
        self.assertIn(('went', 'noun'), words)
        forms = dict(((e['w'], e.get('p')), f) for e, f in entries)
        self.assertIn('went', forms[('go', 'verb')])
        self.assertIn('cafe', forms[('café', 'noun')])

    def test_keeps_form_of_entries_without_their_lemma(self):
        raw = [{'word': 'mice', 'pos': 'noun', 'senses': [
            {'glosses': ['plural of mouse'], 'form_of': [{'word': 'mouse'}]}]}]
        entries = packs.collect(raw, packs.Options())
        self.assertEqual(entries[0][0]['w'], 'mice')

    def test_language_filter(self):
        entries = packs.collect(packs.read_jsonl(ES_JSONL), packs.Options(),
                                {'es'})
        self.assertEqual(sorted(e['w'] for e, _ in entries),
                         ['corazón', 'gato', 'árbol'])

    def test_skips_broken_lines(self):
        raw = list(packs.read_jsonl(EN_JSONL))
        self.assertEqual(len(raw), 14)


class PackTest(unittest.TestCase):
    def test_round_trip(self):
        data, stats = build_en()
        pack = packs.Pack(data)
        self.assertEqual(pack.meta['language'], 'en')
        self.assertEqual(pack.meta['entries'], stats['entries'])
        self.assertEqual(pack.meta['license'], 'CC BY-SA 4.0')
        self.assertIn('Wiktionary contributors', pack.meta['attribution'])
        self.assertEqual(pack.meta['targets'], ['de', 'es', 'fr', 'it', 'no',
                                                'zh'])
        self.assertEqual(stats['size'], len(data))
        self.assertEqual(stats['sha256'], hashlib.sha256(data).hexdigest())

        found = pack.look_up('went')
        self.assertEqual([(e['w'], e['p'], form) for e, form in found],
                         [('went', 'noun', False), ('go', 'verb', True)])
        self.assertEqual([e['w'] for e, _ in pack.look_up('CAFÉ')], ['café'])
        self.assertEqual([e['w'] for e, _ in pack.look_up('cafe')], ['café'])
        self.assertEqual([(e['w'], e['p']) for e, _ in pack.look_up('polish')],
                         [('Polish', 'adj'), ('polish', 'verb')])
        self.assertEqual([(e['p'], f) for e, f in pack.look_up('houses')],
                         [('noun', True), ('verb', True)])
        self.assertEqual(pack.look_up('kerfuffle'), [])

    def test_keys_are_sorted_with_display_forms(self):
        pack = packs.Pack(build_en()[0])
        keys = list(pack.keys())
        names = [key for key, _, _ in keys]
        self.assertEqual(names, sorted(names, key=lambda k: k.encode('utf-8')))
        displays = {key: display for key, display, _ in keys}
        self.assertEqual(displays['cafe'], 'café')
        self.assertEqual(displays['naive'], 'naïve')
        self.assertEqual(displays['polish'], 'Polish')
        self.assertEqual(displays['house'], '')

    def test_reproducible(self):
        self.assertEqual(build_en()[0], build_en()[0])

    def test_small_blocks(self):
        data, stats = build_en(block_size=64)
        self.assertGreater(stats['entryBlocks'], 3)
        self.assertGreater(stats['indexBlocks'], 3)
        pack = packs.Pack(data)
        self.assertEqual(content(pack)[1:], content(packs.Pack(build_en()[0]))[1:])
        self.assertEqual([e['w'] for e, _ in pack.look_up('naive')], ['naïve'])

    def test_layout(self):
        data, _ = build_en()
        self.assertEqual(data[:8], b'MOZHIDCT')
        version, reserved, length = struct.unpack('<HHI', data[8:16])
        self.assertEqual((version, reserved), (1, 0))
        meta = json.loads(data[16:16 + length])
        body = data[16 + length:]
        self.assertEqual(len(body), meta['dataLength'])
        offset, size = meta['layout']['blocks']
        self.assertEqual(offset + size, len(body))
        # Blocks are gzip members.
        self.assertEqual(body[:2], b'\x1f\x8b')

    def test_big_entries_are_trimmed(self):
        sense = {'g': 'g' * 300, 'x': [['x' * 200]] * 2}
        entry = {'w': 'big', 's': [sense] * 120,
                 't': {'de': [['Wort' * 10, 0]] * 50}}
        record = json.loads(packs._entry_record(entry))
        self.assertNotIn('t', record)
        self.assertEqual(len(record['s']), 4)
        self.assertNotIn('x', record['s'][0])

    def test_rejects_damaged_packs(self):
        data, _ = build_en()
        with self.assertRaises(ValueError):
            packs.Pack(b'NOTAPACK' + data[8:])
        with self.assertRaises(ValueError):
            packs.Pack(data[:-1])
        damaged = bytearray(data)
        damaged[-3] ^= 0xff
        with self.assertRaises(ValueError):
            packs.Pack(bytes(damaged))
        with self.assertRaises(ValueError):
            packs.Pack(data[:8] + struct.pack('<HHI', 2, 0, 0) + data[16:])


class CatalogTest(unittest.TestCase):
    def test_catalog_and_dart(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, 'en.mzd')
            data, _ = build_en()
            with open(path, 'wb') as f:
                f.write(data)
            result = packs.catalog([path], 'dictionary-packs-2026-10-22',
                                   'https://example.org/download/', 'page')
            self.assertEqual(result['schemaVersion'], 1)
            self.assertEqual(result['source'], 'page')
            pack = result['packs'][0]
            self.assertEqual(pack['id'], 'en')
            self.assertEqual(pack['url'], 'https://example.org/download/en.mzd')
            self.assertEqual(pack['size'], len(data))
            self.assertEqual(pack['sha256'], hashlib.sha256(data).hexdigest())
            self.assertEqual(pack['entries'], 9)
            dart = packs.dart_catalog(result)
            self.assertIn("const dictionaryCatalogJson = '''", dart)
            self.assertEqual(
                json.loads(dart.split("'''")[1].split("'''")[0]), result)
            escaped = packs.dart_catalog({'release': 'a\\b$c'})
            self.assertIn('"a\\\\\\\\b\\$c"', escaped)
            bad = os.path.join(directory, 'en.bin')
            with open(bad, 'wb') as f:
                f.write(data)
            with self.assertRaises(ValueError):
                packs.catalog([bad], 'r', 'https://example.org')
        with self.assertRaises(ValueError):
            packs.dart_catalog({'release': "'''"})


class CommandLineTest(unittest.TestCase):
    def run_main(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = packs.main(list(argv))
        return code, out.getvalue(), err.getvalue()

    def test_build_dump_catalog_dart(self):
        with tempfile.TemporaryDirectory() as directory:
            pack = os.path.join(directory, 'es.mzd')
            stats = os.path.join(directory, 'stats.json')
            source = os.path.join(directory, 'es.jsonl.gz')
            with open(ES_JSONL, 'rb') as f, gzip.open(source, 'wb') as out:
                out.write(f.read())
            code, _, err = self.run_main(
                'build', source, '--language', 'es', '--lang-code', 'es',
                '--output', pack, '--snapshot', SNAPSHOT, '--stats', stats)
            self.assertEqual(code, 0)
            self.assertIn('Entries', err)
            with open(stats) as f:
                self.assertEqual(json.load(f)['entries'], 3)
            code, out, _ = self.run_main('dump', pack, 'ARBOL', 'gatos')
            self.assertEqual(code, 0)
            self.assertIn('"name": "Spanish"', out)
            self.assertIn('"w": "árbol"', out)
            self.assertIn('The tree is tall.', out)
            self.assertIn('"w": "gato"', out)
            self.assertIn('(form)', out)
            catalog = os.path.join(directory, 'catalog.json')
            code, out, _ = self.run_main(
                'catalog', pack, '--release', 'r', '--base-url',
                'https://example.org')
            self.assertEqual(code, 0)
            with open(catalog, 'w') as f:
                f.write(out)
            self.assertEqual(json.loads(out)['packs'][0]['language'], 'es')
            code, out, _ = self.run_main('dart', catalog)
            self.assertIn('dictionaryCatalogJson', out)

    def test_empty_input(self):
        with tempfile.TemporaryDirectory() as directory:
            source = os.path.join(directory, 'empty.jsonl')
            open(source, 'w').close()
            code, _, err = self.run_main(
                'build', source, '--language', 'xx', '--output',
                os.path.join(directory, 'xx.mzd'))
            self.assertEqual(code, 1)
            self.assertIn('no entries', err)

    def test_kaikki_url(self):
        code, out, _ = self.run_main('kaikki-url', 'es')
        self.assertEqual(code, 0)
        self.assertEqual(out.strip(), 'https://kaikki.org/dictionary/Spanish/'
                         'kaikki.org-dictionary-Spanish.jsonl')
        code, _, err = self.run_main('kaikki-url', 'xx')
        self.assertEqual(code, 1)


class DartFixtureTest(unittest.TestCase):
    """The Dart reader's tests read DART_FIXTURE: it must hold what the tool
    builds from kaikki_en.jsonl (compare content: zlib versions may
    compress differently)."""

    def test_dart_fixture_is_current(self):
        with open(DART_FIXTURE, 'rb') as f:
            fixture = f.read()
        self.assertLess(len(fixture), 50 * 1024)
        self.assertEqual(content(packs.Pack(fixture)),
                         content(packs.Pack(build_en()[0])),
                         'Run python3 tool/dictionary_packs_test.py --update')


if __name__ == '__main__':
    if '--update' in sys.argv:
        os.makedirs(os.path.dirname(DART_FIXTURE), exist_ok=True)
        with open(DART_FIXTURE, 'wb') as f:
            f.write(build_en()[0])
        print(f'wrote {DART_FIXTURE}')
        sys.exit(0)
    unittest.main()
