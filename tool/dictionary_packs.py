#!/usr/bin/env python3
"""Build Mozhi's offline dictionary packs from Wiktionary data.

The input is wiktextract's JSONL (one JSON object per word entry, as
kaikki.org publishes it per language). The output is a dictionary pack:
the compact, versioned format that the app reads lazily on Android and on
the web (packages/translation_repository/lib/src/dictionary_packs/, format
in docs/dictionary-packs.md). Only what the app shows is kept: part of
speech, IPA, senses (gloss, qualifiers, a few examples), synonyms, related
words, a short etymology and translations into the pack's target
languages; inflection tables, templates, audio, categories and the rest
are dropped. Inflected forms become lookup keys of their lemma.

Usage:
  python3 tool/dictionary_packs.py build INPUT.jsonl[.gz] --language es \\
      --output es.mzd [--snapshot 2026-10-15] [--stats stats.json]
  python3 tool/dictionary_packs.py catalog --release dictionary-packs-2026-10-22 \\
      --base-url https://github.com/Aimdi/Mozhi/releases/download/dictionary-packs-2026-10-22 \\
      packs/*.mzd > dictionary_catalog.json
  python3 tool/dictionary_packs.py dart dictionary_catalog.json \\
      > lib/dictionary/data/dictionary_catalog_data.dart
  python3 tool/dictionary_packs.py kaikki-url es   # where the CI job downloads
  python3 tool/dictionary_packs.py dump es.mzd [WORD ...]

Packs are reproducible: the same input and options give the same bytes
(gzip with mtime 0). Data from Wiktionary is CC BY-SA 4.0 (and GFDL); the
attribution is written into every pack and shown by the app.

Tests: python3 tool/dictionary_packs_test.py
"""

import argparse
import gzip
import hashlib
import json
import os
import re
import struct
import sys
import unicodedata

MAGIC = b'MOZHIDCT'
FORMAT = 1
BLOCK_SIZE = 64 * 1024
MAX_REFS = 32
MAX_ENTRY_BYTES = 32 * 1024
PACK_EXTENSION = '.mzd'

SPACES = re.compile(
    '[\t\n\x0b\f\r \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f'
    '\u3000\ufeff]+')

LICENSE = 'CC BY-SA 4.0'
LICENSE_URL = 'https://creativecommons.org/licenses/by-sa/4.0/'
SOURCE = 'Wiktionary'
EXTRACTOR = 'wiktextract (kaikki.org)'

# English names as kaikki.org spells them in its per-language URLs.
KAIKKI_NAMES = {
    'af': 'Afrikaans', 'ar': 'Arabic', 'bg': 'Bulgarian', 'ca': 'Catalan',
    'cs': 'Czech', 'cy': 'Welsh', 'da': 'Danish', 'de': 'German',
    'el': 'Greek', 'en': 'English', 'eo': 'Esperanto', 'es': 'Spanish',
    'et': 'Estonian', 'eu': 'Basque', 'fa': 'Persian', 'fi': 'Finnish',
    'fr': 'French', 'ga': 'Irish', 'gl': 'Galician', 'he': 'Hebrew',
    'hi': 'Hindi', 'hu': 'Hungarian', 'hy': 'Armenian', 'id': 'Indonesian',
    'is': 'Icelandic', 'it': 'Italian', 'ja': 'Japanese', 'ka': 'Georgian',
    'ko': 'Korean', 'la': 'Latin', 'lt': 'Lithuanian', 'lv': 'Latvian',
    'mk': 'Macedonian', 'ms': 'Malay', 'nl': 'Dutch', 'no': 'Norwegian',
    'pl': 'Polish', 'pt': 'Portuguese', 'ro': 'Romanian', 'ru': 'Russian',
    'sk': 'Slovak', 'sl': 'Slovene', 'sq': 'Albanian',
    'sr': 'Serbo-Croatian', 'sv': 'Swedish', 'sw': 'Swahili', 'ta': 'Tamil',
    'th': 'Thai', 'tl': 'Tagalog', 'tr': 'Turkish', 'uk': 'Ukrainian',
    'ur': 'Urdu', 'vi': 'Vietnamese', 'zh': 'Chinese',
}
KAIKKI_URL = ('https://kaikki.org/dictionary/{name}/'
              'kaikki.org-dictionary-{file}.jsonl')

# Languages English entries keep translations into (the app's offline
# languages and a few more), as app language codes.
DEFAULT_TARGETS = (
    'af ar az be bg bn bs ca cs cy da de el eo es et eu fa fi fr ga gl gu '
    'he hi hr hu hy id is it ja ka kn ko la lt lv mk ml mr ms nl no pl pt '
    'ro ru sk sl sq sr sv sw ta te th tl tr uk ur vi zh').split()

# Wiktionary language codes in translation tables -> app language codes.
CODE_ALIASES = {
    'cmn': 'zh', 'nb': 'no', 'fil': 'tl', 'iw': 'he', 'in': 'id',
    'sh': 'sr', 'pes': 'fa', 'arb': 'ar', 'zsm': 'ms', 'ekk': 'et',
    'lvs': 'lv', 'khk': 'mn',
}

# Sense and form tags that only matter to wiktextract.
INTERNAL_TAGS = {
    'form-of', 'alt-of', 'no-gloss', 'morpheme', 'error-unknown-tag',
    'table-tags', 'inflection-template', 'class', 'canonical', 'romanization',
    'excessive-tags', 'empty-gloss', 'Template:',
}
SKIPPED_FORM_TAGS = {
    'table-tags', 'inflection-template', 'class', 'auxiliary', 'source',
    'canonical',
}


class Options:
    """What a pack keeps (the defaults fit the app's dictionary screens)."""

    def __init__(self, max_senses=12, max_examples=2, max_words=12,
                 max_translations=4, max_forms=64, max_example_chars=220,
                 max_etymology_chars=300, targets=None):
        self.max_senses = max_senses
        self.max_examples = max_examples
        self.max_words = max_words
        self.max_translations = max_translations
        self.max_forms = max_forms
        self.max_example_chars = max_example_chars
        self.max_etymology_chars = max_etymology_chars
        self.targets = set(DEFAULT_TARGETS if targets is None else targets)


# --- Folding -----------------------------------------------------------------


def fold_char(char):
    """The key text of one code point: Unicode case folding, then canonical
    decomposition without the combining diacritics U+0300-U+036F, then
    recomposition (so kana, Hangul and Indic vowel signs stay). Curly
    apostrophes become '."""
    if char in '‘’ʼ':
        return "'"
    if '\u0300' <= char <= '\u036f':
        return ''
    decomposed = unicodedata.normalize('NFD', char.casefold())
    stripped = ''.join(c for c in decomposed if not '\u0300' <= c <= '\u036f')
    return unicodedata.normalize('NFC', stripped)


def collapse_spaces(text):
    return SPACES.sub(' ', text).strip(' ')


def fold(text, table=None):
    """The lookup key of [text]: every code point folded (through [table],
    the pack's fold table, when given), spaces collapsed."""
    if table is None:
        folded = ''.join(fold_char(c) for c in text)
    else:
        folded = ''.join(table.get(c, c) for c in text)
    return collapse_spaces(folded)


def fold_table(texts):
    """The fold of every character [texts] use, in each case, plus the
    combining diacritics and curly apostrophes, where it changes it."""
    chars = {chr(c) for c in range(0x300, 0x370)} | set('‘’ʼ')
    for text in texts:
        for char in text:
            chars.add(char)
            for variant in (char.upper(), char.lower(), char.title()):
                chars.update(variant)
    table = {}
    for char in sorted(chars):
        folded = fold_char(char)
        if folded != char:
            table[char] = folded
    return table


# --- Trimming wiktextract entries ------------------------------------------


def _clean(text, limit=None):
    if not isinstance(text, str):
        return ''
    text = collapse_spaces(text)
    if limit is not None and len(text) > limit:
        text = text[:limit - 1].rstrip() + '…'
    return text


def _valid(text):
    try:
        text.encode('utf-8')
    except UnicodeEncodeError:
        return False
    return True


def _words(items):
    for item in items or ():
        word = item.get('word') if isinstance(item, dict) else item
        word = _clean(word)
        if word and _valid(word):
            yield word


def _add_unique(target, words, limit, exclude=()):
    for word in words:
        if len(target) >= limit:
            return
        if word not in target and word not in exclude:
            target.append(word)


def _ipa(raw):
    for sound in raw.get('sounds') or ():
        if isinstance(sound, dict) and isinstance(sound.get('ipa'), str):
            ipa = _clean(sound['ipa']).strip('/[]').strip()
            if ipa and len(ipa) <= 80:
                return ipa
    return ''


def _overlap(label, gloss):
    tokens = lambda text: {t for t in re.findall(r'\w+', text.lower())
                           if len(t) > 2}
    return len(tokens(label) & tokens(gloss))


def _sense_index(label, glosses):
    """The sense a translation table labelled [label] belongs to: the gloss
    sharing the most words with it, else -1 (the whole entry)."""
    if not label:
        return -1
    best, index = 0, -1
    for i, gloss in enumerate(glosses):
        score = _overlap(label, gloss)
        if score > best:
            best, index = score, i
    return index


def trim_entry(raw, options):
    """(entry, forms) for one wiktextract word entry, or None when it has
    nothing the app shows."""
    if not isinstance(raw, dict):
        return None
    word = _clean(raw.get('word'))
    if not word or len(word) > 100 or not _valid(word):
        return None
    senses = []
    synonyms = []
    related = []
    sense_translations = []
    for raw_sense in raw.get('senses') or ():
        if not isinstance(raw_sense, dict):
            continue
        tags = [t for t in raw_sense.get('tags') or () if isinstance(t, str)]
        if 'no-gloss' in tags:
            continue
        glosses = raw_sense.get('glosses') or raw_sense.get('raw_glosses')
        if not glosses or not isinstance(glosses[-1], str):
            continue
        gloss = _clean(glosses[-1], 400)
        if not gloss or not _valid(gloss):
            continue
        if len(senses) >= options.max_senses:
            break
        sense = {'g': gloss}
        qualifiers = [t for t in tags if t not in INTERNAL_TAGS][:4]
        qualifier = _clean(raw_sense.get('qualifier'))
        if qualifier:
            qualifiers.append(qualifier)
        if qualifiers:
            sense['q'] = ', '.join(qualifiers)
        examples = []
        raw_examples = [e for e in raw_sense.get('examples') or ()
                        if isinstance(e, dict)]
        # Usage examples first, then short quotations.
        raw_examples.sort(key=lambda e: e.get('type') == 'quotation')
        for example in raw_examples:
            if len(examples) >= options.max_examples:
                break
            text = _clean(example.get('text'))
            if not text or len(text) > options.max_example_chars:
                continue
            translation = _clean(example.get('translation')
                                 or example.get('english'),
                                 options.max_example_chars)
            if not _valid(text + translation):
                continue
            examples.append([text, translation] if translation else [text])
        if examples:
            sense['x'] = examples
        lemma = next(_words(raw_sense.get('form_of')), '') or next(
            _words(raw_sense.get('alt_of')), '')
        if lemma:
            sense['o'] = lemma
        senses.append(sense)
        _add_unique(synonyms, _words(raw_sense.get('synonyms')),
                    options.max_words, (word,))
        _add_unique(related, _words(raw_sense.get('antonyms')),
                    options.max_words, (word,))
        for translation in raw_sense.get('translations') or ():
            sense_translations.append((len(senses) - 1, translation))
    if not senses:
        return None

    _add_unique(synonyms, _words(raw.get('synonyms')), options.max_words,
                (word,))
    for key in ('antonyms', 'related', 'derived'):
        _add_unique(related, _words(raw.get(key)), options.max_words, (word,))

    glosses = [sense['g'] for sense in senses]
    translations = {}
    candidates = [(_sense_index(_clean(t.get('sense')), glosses), t)
                  for t in raw.get('translations') or ()
                  if isinstance(t, dict)]
    candidates += [(i, t) for i, t in sense_translations if isinstance(t, dict)]
    for index, translation in candidates:
        code = translation.get('code') or ''
        if not isinstance(code, str):
            continue
        code = CODE_ALIASES.get(code, code)
        if code not in options.targets:
            continue
        rendering = _clean(translation.get('word'), 80)
        if not rendering or not _valid(rendering):
            continue
        items = translations.setdefault(code, [])
        if [rendering, index] in items:
            continue
        if sum(1 for _, i in items if i == index) >= options.max_translations:
            continue
        items.append([rendering, index])

    forms = []
    for form in raw.get('forms') or ():
        if not isinstance(form, dict) or len(forms) >= options.max_forms:
            continue
        tags = set(t for t in form.get('tags') or () if isinstance(t, str))
        if tags & SKIPPED_FORM_TAGS:
            continue
        text = _clean(form.get('form'))
        if (not text or text == word or text == '-' or len(text) > 60
                or len(text.split(' ')) > 3 or not _valid(text)
                or text in forms):
            continue
        forms.append(text)

    entry = {'w': word}
    pos = _clean(raw.get('pos'))
    if pos:
        entry['p'] = pos
    ipa = _ipa(raw)
    if ipa:
        entry['i'] = ipa
    entry['s'] = senses
    if synonyms:
        entry['y'] = synonyms
    if related:
        entry['r'] = related
    etymology = _clean(raw.get('etymology_text'), options.max_etymology_chars)
    if etymology and _valid(etymology):
        entry['e'] = etymology
    if translations:
        entry['t'] = {code: translations[code] for code in sorted(translations)}
    return entry, forms


def is_form_of(entry):
    return all('o' in sense for sense in entry['s'])


def read_jsonl(path):
    """The objects of a JSONL file (`.gz` too); bad lines are skipped."""
    opener = gzip.open if path.endswith('.gz') else open
    with opener(path, 'rt', encoding='utf-8', errors='replace') as lines:
        for line in lines:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except ValueError:
                continue


def collect(raw_entries, options, language_codes=None):
    """Trimmed (entry, forms) pairs: entries that only point to a lemma the
    data has become inflected forms of that lemma."""
    entries = []
    for raw in raw_entries:
        if language_codes and raw.get('lang_code') not in language_codes:
            continue
        trimmed = trim_entry(raw, options)
        if trimmed:
            entries.append(trimmed)
    by_word = {}
    by_key = {}
    for index, (entry, _) in enumerate(entries):
        if not is_form_of(entry):
            by_word.setdefault(entry['w'], []).append(index)
            by_key.setdefault(fold(entry['w']), []).append(index)
    kept = []
    for entry, forms in entries:
        if is_form_of(entry):
            lemmas = {sense['o'] for sense in entry['s']}
            targets = [by_word.get(lemma) or by_key.get(fold(lemma))
                       for lemma in lemmas]
            if all(targets):
                for indices in targets:
                    for index in indices:
                        lemma_forms = entries[index][1]
                        if (entry['w'] not in lemma_forms
                                and entry['w'] != entries[index][0]['w']):
                            lemma_forms.append(entry['w'])
                continue
        kept.append((entry, forms))
    return kept


# --- Writing packs -----------------------------------------------------------


def _varint(value):
    out = bytearray()
    while value >= 0x80:
        out.append((value & 0x7f) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)


def _string(text):
    data = text.encode('utf-8')
    return _varint(len(data)) + data


def _compress(data):
    return gzip.compress(data, compresslevel=9, mtime=0)


def _entry_record(entry):
    data = json.dumps(entry, ensure_ascii=False,
                      separators=(',', ':')).encode('utf-8')
    if len(data) <= MAX_ENTRY_BYTES:
        return data
    entry = dict(entry)
    entry.pop('t', None)
    entry['s'] = [{k: v for k, v in s.items() if k != 'x'} for s in entry['s']]
    data = json.dumps(entry, ensure_ascii=False,
                      separators=(',', ':')).encode('utf-8')
    if len(data) > MAX_ENTRY_BYTES:
        entry['s'] = entry['s'][:4]
        data = json.dumps(entry, ensure_ascii=False,
                          separators=(',', ':')).encode('utf-8')
    return data


def write_pack(entries, language, name='', gloss_language='en', snapshot='',
               targets=(), source_url='https://en.wiktionary.org/',
               attribution=None, block_size=BLOCK_SIZE):
    """The bytes of a pack of [entries] ((entry, forms) pairs) and its
    statistics. The layout matches DictionaryPackWriter (Dart)."""
    table = fold_table(text for entry, forms in entries
                       for text in [entry['w'], *forms])
    keyed = [(fold(entry['w'], table).encode('utf-8'), index, entry, forms)
             for index, (entry, forms) in enumerate(entries)]
    keyed = [item for item in keyed if item[0]]
    keyed.sort(key=lambda item: (item[0], item[1]))

    keys = {}

    def key_info(key):
        return keys.setdefault(key, {'direct': [], 'forms': [],
                                     'direct_display': None,
                                     'form_display': None})

    for entry_id, (key, _, entry, _) in enumerate(keyed):
        info = key_info(key.decode('utf-8'))
        if info['direct_display'] is None:
            info['direct_display'] = entry['w']
        info['direct'].append(entry_id * 2)
    for entry_id, (key, _, entry, forms) in enumerate(keyed):
        own = key.decode('utf-8')
        for form in forms:
            form_key = fold(form, table)
            if not form_key or form_key == own:
                continue
            info = key_info(form_key)
            if info['form_display'] is None:
                info['form_display'] = form
            ref = entry_id * 2 + 1
            if ref not in info['forms']:
                info['forms'].append(ref)

    data = bytearray()
    stats = {'entryBytes': 0, 'entryBlocksBytes': 0, 'indexBytes': 0,
             'indexBlocksBytes': 0}
    blocks = []
    block = bytearray()
    first = 0

    def flush_entries(next_id):
        nonlocal block, first
        if not block:
            return
        stats['entryBytes'] += len(block)
        compressed = _compress(bytes(block))
        stats['entryBlocksBytes'] += len(compressed)
        blocks.append((len(data), len(compressed), first))
        data.extend(compressed)
        block = bytearray()
        first = next_id

    for entry_id, (_, _, entry, _) in enumerate(keyed):
        record = _entry_record(entry)
        size = len(_varint(len(record))) + len(record)
        if block and len(block) + size > block_size:
            flush_entries(entry_id)
        block += _varint(len(record)) + record
    flush_entries(len(keyed))

    directory = []
    index = bytearray()
    first_key = None
    previous = None

    def key_record(key, key_bytes, info, before):
        shared = 0
        if before is not None:
            limit = min(len(before), len(key_bytes))
            while shared < limit and before[shared] == key_bytes[shared]:
                shared += 1
        display = info['direct_display'] or info['form_display'] or ''
        if display == key:
            display = ''
        refs = (info['direct'] + info['forms'])[:MAX_REFS]
        out = bytearray(_varint(shared))
        out += _varint(len(key_bytes) - shared) + key_bytes[shared:]
        out += _string(display) + _varint(len(refs))
        for ref in refs:
            out += _varint(ref)
        return bytes(out)

    def flush_keys():
        nonlocal index, previous
        if not index:
            return
        stats['indexBytes'] += len(index)
        compressed = _compress(bytes(index))
        stats['indexBlocksBytes'] += len(compressed)
        directory.append((len(data), len(compressed), first_key))
        data.extend(compressed)
        index = bytearray()
        previous = None

    for key in sorted(keys, key=lambda k: k.encode('utf-8')):
        key_bytes = key.encode('utf-8')
        record = key_record(key, key_bytes, keys[key], previous)
        if index and len(index) + len(record) > block_size:
            flush_keys()
            record = key_record(key, key_bytes, keys[key], None)
        if not index:
            first_key = key_bytes
        index += record
        previous = key_bytes
    flush_keys()

    directory_bytes = bytearray(_varint(len(directory)))
    for offset, length, key_bytes in directory:
        directory_bytes += (_varint(offset) + _varint(length)
                            + _varint(len(key_bytes)) + key_bytes)
    directory_offset = len(data)
    data += directory_bytes
    blocks_bytes = bytearray(_varint(len(blocks)))
    for offset, length, first_id in blocks:
        blocks_bytes += _varint(offset) + _varint(length) + _varint(first_id)
    blocks_offset = len(data)
    data += blocks_bytes
    body = bytes(data)

    if attribution is None:
        attribution = default_attribution(name or language, snapshot,
                                          source_url)
    metadata = {
        'format': FORMAT,
        'language': language,
        'glossLanguage': gloss_language,
        'name': name,
        'source': SOURCE,
        'sourceUrl': source_url,
        'extractor': EXTRACTOR,
        'snapshot': snapshot,
        'license': LICENSE,
        'licenseUrl': LICENSE_URL,
        'attribution': attribution,
        'targets': sorted(targets),
        'entries': len(keyed),
        'keys': len(keys),
        'blockSize': block_size,
        'fold': table,
        'layout': {
            'directory': [directory_offset, len(directory_bytes)],
            'blocks': [blocks_offset, len(blocks_bytes)],
        },
        'dataLength': len(body),
        'sha256': hashlib.sha256(body).hexdigest(),
    }
    meta = json.dumps(metadata, ensure_ascii=False,
                      separators=(',', ':')).encode('utf-8')
    pack = MAGIC + struct.pack('<HHI', FORMAT, 0, len(meta)) + meta + body
    stats.update({
        'language': language,
        'entries': len(keyed),
        'keys': len(keys),
        'entryBlocks': len(blocks),
        'indexBlocks': len(directory),
        'metadataBytes': len(meta),
        'size': len(pack),
        'sha256': hashlib.sha256(pack).hexdigest(),
    })
    return pack, stats


def default_attribution(name, snapshot, source_url):
    when = f' on {snapshot}' if snapshot else ''
    return (
        f'{name} entries from Wiktionary ({source_url}), by Wiktionary '
        f'contributors, available under the Creative Commons '
        f'Attribution-ShareAlike 4.0 licence ({LICENSE_URL}) and the GNU '
        f'Free Documentation License. Extracted with wiktextract '
        f'(https://github.com/tatuylonen/wiktextract, kaikki.org){when}. '
        'Changes: shortened to definitions, pronunciation, examples, '
        'synonyms, related words, short etymologies and translations; '
        'inflected forms point to their lemma.')


# --- Reading packs (dump, catalogue, tests) ---------------------------------


class Pack:
    """Reads a pack the way the app does (for `dump`, `catalog` and the
    tests)."""

    def __init__(self, data):
        if data[:8] != MAGIC:
            raise ValueError('Not a dictionary pack')
        version, _, length = struct.unpack('<HHI', data[8:16])
        if version != FORMAT:
            raise ValueError(f'Unsupported format {version}')
        self.meta = json.loads(data[16:16 + length].decode('utf-8'))
        self.data = data[16 + length:]
        if len(self.data) != self.meta['dataLength']:
            raise ValueError('Wrong length')
        if hashlib.sha256(self.data).hexdigest() != self.meta['sha256']:
            raise ValueError('SHA-256 mismatch')
        layout = self.meta['layout']
        reader = _Reader(self._section(layout['directory']))
        self.directory = []
        for _ in range(reader.varint()):
            offset, length = reader.varint(), reader.varint()
            self.directory.append((offset, length, reader.take(reader.varint())))
        reader = _Reader(self._section(layout['blocks']))
        self.blocks = [(reader.varint(), reader.varint(), reader.varint())
                       for _ in range(reader.varint())]

    def _section(self, span):
        offset, length = span
        return self.data[offset:offset + length]

    def _block(self, offset, length):
        return gzip.decompress(self.data[offset:offset + length])

    def keys(self):
        """(key, display, refs) of every key, in order."""
        for offset, length, _ in self.directory:
            reader = _Reader(self._block(offset, length))
            previous = b''
            while not reader.at_end():
                shared = reader.varint()
                key = previous[:shared] + reader.take(reader.varint())
                display = reader.take(reader.varint()).decode('utf-8')
                refs = [reader.varint() for _ in range(reader.varint())]
                yield key.decode('utf-8'), display, refs
                previous = key

    def entries(self):
        for offset, length, _ in self.blocks:
            reader = _Reader(self._block(offset, length))
            while not reader.at_end():
                yield json.loads(reader.take(reader.varint()).decode('utf-8'))

    def look_up(self, word):
        """[(entry, via_form)] for [word], folded with the pack's table."""
        key = fold(word, self.meta['fold'])
        entries = list(self.entries())
        for candidate, _, refs in self.keys():
            if candidate == key:
                return [(entries[ref >> 1], bool(ref & 1)) for ref in refs]
        return []


class _Reader:
    def __init__(self, data):
        self.data = data
        self.position = 0

    def at_end(self):
        return self.position >= len(self.data)

    def varint(self):
        result = shift = 0
        while True:
            byte = self.data[self.position]
            self.position += 1
            result |= (byte & 0x7f) << shift
            if not byte & 0x80:
                return result
            shift += 7

    def take(self, length):
        value = self.data[self.position:self.position + length]
        self.position += length
        return bytes(value)


# --- Catalogue ---------------------------------------------------------------


def catalog(paths, release, base_url, source=None):
    """The app's dictionary_catalog.json for the packs at [paths]."""
    packs = []
    for path in paths:
        with open(path, 'rb') as f:
            data = f.read()
        meta = Pack(data).meta
        file_name = os.path.basename(path)
        if not file_name.endswith(PACK_EXTENSION):
            raise ValueError(f'{file_name}: packs end with {PACK_EXTENSION}')
        packs.append({
            'id': file_name[:-len(PACK_EXTENSION)],
            'language': meta['language'],
            'glossLanguage': meta['glossLanguage'],
            'name': meta['name'] or meta['language'],
            'file': file_name,
            'url': f'{base_url.rstrip("/")}/{file_name}',
            'size': len(data),
            'sha256': hashlib.sha256(data).hexdigest(),
            'entries': meta['entries'],
            'snapshot': meta['snapshot'],
            'license': meta['license'],
            'source': meta['source'],
        })
    packs.sort(key=lambda pack: pack['name'])
    result = {'schemaVersion': 1, 'release': release}
    if source:
        result['source'] = source
    result['packs'] = packs
    return result


def dart_catalog(catalog_json):
    """lib/dictionary/data/dictionary_catalog_data.dart for [catalog_json]
    (the app pins the packs' sizes and SHA-256 at build time)."""
    text = json.dumps(catalog_json, ensure_ascii=False, indent=2)
    if "'''" in text:
        raise ValueError("The catalogue can't contain '''")
    text = text.replace('\\', '\\\\').replace('$', '\\$')
    return (
        '// Generated by `python3 tool/dictionary_packs.py dart`: the\n'
        '// dictionary packs of the release named below, with their sizes and\n'
        '// SHA-256 (see docs/dictionary-packs.md). Do not edit by hand.\n'
        '\n'
        '/// The bundled dictionary pack catalogue (`dictionary_catalog.json`'
        '\n/// of the latest `dictionary-packs-<date>` release).\n'
        f"const dictionaryCatalogJson = '''\n{text}\n''';\n")


# --- Command line ------------------------------------------------------------


def _format_size(size):
    for unit in ('B', 'KB', 'MB', 'GB'):
        if size < 1024 or unit == 'GB':
            return f'{size:.1f} {unit}' if unit != 'B' else f'{size} B'
        size /= 1024
    return f'{size} B'


def _report(stats, out):
    rows = [
        ('Entries', f'{stats["entries"]:,}'),
        ('Keys (headwords and forms)', f'{stats["keys"]:,}'),
        ('Entry data', f'{_format_size(stats["entryBytes"])} -> '
                       f'{_format_size(stats["entryBlocksBytes"])} gzip '
                       f'({stats["entryBlocks"]} blocks)'),
        ('Key index', f'{_format_size(stats["indexBytes"])} -> '
                      f'{_format_size(stats["indexBlocksBytes"])} gzip '
                      f'({stats["indexBlocks"]} blocks)'),
        ('Metadata', _format_size(stats['metadataBytes'])),
        ('Pack', _format_size(stats['size'])),
        ('SHA-256', stats['sha256']),
    ]
    for label, value in rows:
        print(f'{label:28} {value}', file=out)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)

    build = commands.add_parser('build', help='JSONL -> pack')
    build.add_argument('input', help='wiktextract JSONL (.jsonl or .jsonl.gz)')
    build.add_argument('--language', required=True,
                       help='app code of the words, e.g. es')
    build.add_argument('--output', required=True)
    build.add_argument('--name', default='',
                       help='English name (default: from the data)')
    build.add_argument('--gloss-language', default='en')
    build.add_argument('--lang-code', action='append', default=[],
                       help='keep only entries with this lang_code '
                            '(default: all; repeat for several)')
    build.add_argument('--snapshot', default='', help='date of the data')
    build.add_argument('--source-url', default='https://en.wiktionary.org/')
    build.add_argument('--targets', default=','.join(DEFAULT_TARGETS),
                       help='translation languages (comma separated)')
    build.add_argument('--max-senses', type=int, default=12)
    build.add_argument('--max-examples', type=int, default=2)
    build.add_argument('--max-translations', type=int, default=4)
    build.add_argument('--max-forms', type=int, default=64)
    build.add_argument('--stats', help='also write the statistics as JSON')

    cat = commands.add_parser('catalog', help='packs -> dictionary_catalog.json')
    cat.add_argument('packs', nargs='+')
    cat.add_argument('--release', required=True)
    cat.add_argument('--base-url', required=True)
    cat.add_argument('--source', help='the release page')

    dart = commands.add_parser('dart', help='catalogue -> Dart constant')
    dart.add_argument('catalog')

    url = commands.add_parser('kaikki-url', help="kaikki.org's JSONL URL")
    url.add_argument('language')

    dump = commands.add_parser('dump', help='print a pack')
    dump.add_argument('pack')
    dump.add_argument('words', nargs='*')

    args = parser.parse_args(argv)
    if args.command == 'build':
        targets = [t.strip() for t in args.targets.split(',') if t.strip()]
        options = Options(max_senses=args.max_senses,
                          max_examples=args.max_examples,
                          max_translations=args.max_translations,
                          max_forms=args.max_forms,
                          targets=[t for t in targets if t != args.language])
        name = args.name
        first = []

        def entries():
            for raw in read_jsonl(args.input):
                if not first and isinstance(raw, dict):
                    first.append(raw.get('lang') or '')
                yield raw

        collected = collect(entries(), options, set(args.lang_code))
        if not collected:
            print(f'{args.input}: no entries', file=sys.stderr)
            return 1
        used = sorted({code for entry, _ in collected
                       for code in entry.get('t', {})})
        pack, stats = write_pack(
            collected, args.language, name=name or (first[0] if first else ''),
            gloss_language=args.gloss_language, snapshot=args.snapshot,
            targets=used, source_url=args.source_url)
        with open(args.output, 'wb') as f:
            f.write(pack)
        _report(stats, sys.stderr)
        if args.stats:
            with open(args.stats, 'w') as f:
                json.dump(stats, f, indent=2)
        return 0
    if args.command == 'catalog':
        json.dump(catalog(args.packs, args.release, args.base_url, args.source),
                  sys.stdout, ensure_ascii=False, indent=2)
        sys.stdout.write('\n')
        return 0
    if args.command == 'dart':
        with open(args.catalog, encoding='utf-8') as f:
            sys.stdout.write(dart_catalog(json.load(f)))
        return 0
    if args.command == 'kaikki-url':
        name = KAIKKI_NAMES.get(args.language)
        if not name:
            print(f'No kaikki.org name for {args.language}', file=sys.stderr)
            return 1
        print(KAIKKI_URL.format(name=name.replace(' ', '%20'),
                                file=name.replace(' ', '')))
        return 0
    with open(args.pack, 'rb') as f:
        pack = Pack(f.read())
    meta = {k: v for k, v in pack.meta.items() if k != 'fold'}
    print(json.dumps(meta, ensure_ascii=False, indent=2))
    for word in args.words:
        print(f'\n{word}:')
        for entry, via_form in pack.look_up(word):
            marker = ' (form)' if via_form else ''
            print(f'  {json.dumps(entry, ensure_ascii=False)}{marker}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
