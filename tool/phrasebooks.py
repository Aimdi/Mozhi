#!/usr/bin/env python3
"""Build Mozhi's starter phrasebooks from Wikivoyage's phrasebooks.

The input is the wikitext of an English Wikivoyage phrasebook article
("Portuguese phrasebook"), from the MediaWiki API (`fetch`, at a pinned
revision) or a dump. Its phrase list ("Basics", "Numbers", "Time",
"Directions", "Eating"...) is written in definition-list lines:

  ; Hello. : Olá. (''oh-LAH'')
  ; How are you?
  : Como vai você? (''KOH-moo vai voh-SAY'')
  * Thank you : Obrigado (''oh-bree-GAH-doo'')

(the English phrase, then the foreign one, then the pronunciation in
italics between parentheses; also `{{phrasebook|English|Foreign|Pron}}`).
The output is a starter phrasebook pack: gzip'd JSON (format
`mozhi-phrasebook` 1, docs/phrasebook.md) with the phrases by section and
the credit the licence asks for (page, revision, authors, licence).

Usage:
  python3 tool/phrasebooks.py fetch pt [--revision 123456] --output pt.page.json
  python3 tool/phrasebooks.py build pt.page.json --language pt --output pt.json.gz \\
      [--retrieved 2026-10-22] [--stats pt.stats.json]
  python3 tool/phrasebooks.py build page.wikitext --language pt --title \\
      "Portuguese phrasebook" --revision 123456 --output pt.json.gz
  python3 tool/phrasebooks.py catalog --release phrasebooks-2026-10-22 \\
      --base-url https://github.com/Aimdi/Mozhi/releases/download/phrasebooks-2026-10-22 \\
      packs/*.json.gz > phrasebook_catalog.json
  python3 tool/phrasebooks.py dart phrasebook_catalog.json \\
      > lib/phrasebook/data/starter_catalog_data.dart
  python3 tool/phrasebooks.py pages            # the languages and their pages
  python3 tool/phrasebooks.py dump pt.json.gz

Packs are reproducible: the same wikitext and options give the same bytes
(sorted keys, gzip with mtime 0). Wikivoyage's text is CC BY-SA 4.0, by
Wikivoyage contributors; every pack carries the attribution and the app
shows it. Standard library only.

Tests: python3 tool/phrasebooks_test.py
"""

import argparse
import gzip
import hashlib
import html
import io
import json
import os
import re
import sys
import urllib.parse
import urllib.request

FORMAT = 'mozhi-phrasebook'
FORMAT_VERSION = 1
PACK_EXTENSION = '.json.gz'
SITE = 'en.wikivoyage.org'
LICENSE = 'CC BY-SA 4.0'
LICENSE_URL = 'https://creativecommons.org/licenses/by-sa/4.0/'
SOURCE = 'Wikivoyage'
USER_AGENT = ('MozhiPhrasebookBuilder/1.0 '
              '(https://github.com/Aimdi/Mozhi; tool/phrasebooks.py)')

MAX_PHRASES = 3000
MAX_TEXT = 300
MAX_PACK_BYTES = 4 * 1024 * 1024  # the app's StarterPhrasebookInfo.maxSize

# App language code -> English name and the English Wikivoyage article.
PAGES = {
    'ar': ('Arabic', 'Arabic phrasebook'),
    'cs': ('Czech', 'Czech phrasebook'),
    'da': ('Danish', 'Danish phrasebook'),
    'de': ('German', 'German phrasebook'),
    'el': ('Greek', 'Greek phrasebook'),
    'es': ('Spanish', 'Spanish phrasebook'),
    'fi': ('Finnish', 'Finnish phrasebook'),
    'fr': ('French', 'French phrasebook'),
    'he': ('Hebrew', 'Hebrew phrasebook'),
    'hi': ('Hindi', 'Hindi phrasebook'),
    'hr': ('Croatian', 'Croatian phrasebook'),
    'hu': ('Hungarian', 'Hungarian phrasebook'),
    'id': ('Indonesian', 'Indonesian phrasebook'),
    'it': ('Italian', 'Italian phrasebook'),
    'ja': ('Japanese', 'Japanese phrasebook'),
    'ko': ('Korean', 'Korean phrasebook'),
    'nl': ('Dutch', 'Dutch phrasebook'),
    'no': ('Norwegian', 'Norwegian phrasebook'),
    'pl': ('Polish', 'Polish phrasebook'),
    'pt': ('Portuguese', 'Portuguese phrasebook'),
    'ro': ('Romanian', 'Romanian phrasebook'),
    'ru': ('Russian', 'Russian phrasebook'),
    'sv': ('Swedish', 'Swedish phrasebook'),
    'sw': ('Swahili', 'Swahili phrasebook'),
    'th': ('Thai', 'Thai phrasebook'),
    'tr': ('Turkish', 'Turkish phrasebook'),
    'uk': ('Ukrainian', 'Ukrainian phrasebook'),
    'vi': ('Vietnamese', 'Vietnamese phrasebook'),
    'zh': ('Chinese', 'Chinese phrasebook'),
}

# Sections that hold no phrases (guides, grammar, reading lists).
SKIPPED_SECTIONS = {
    'pronunciation', 'pronunciation guide', 'vowels', 'consonants',
    'common diphthongs', 'diphthongs', 'stress', 'grammar', 'tones',
    'writing system', 'script', 'alphabet', 'learning more', 'further reading',
    'see also', 'understand', 'external links', 'references', 'notes',
    'dialects', 'regional variations', 'phrase list',
}

_ID = re.compile(r'^[a-z]{2,3}(-[a-z0-9]{2,8})*$')
_HEADING = re.compile(r'^(={2,6})\s*(.*?)\s*\1\s*$')
_SPACES = re.compile(r'\s+')


# --- Wikitext ----------------------------------------------------------------


def _strip_templates(text):
    """[text] without its templates: `{{lang|pt|Olá}}` keeps its last
    argument, `{{IPA|...}}`-like and other templates go."""
    keep_last = {'lang', 'lang-pt', 'transl', 'nowrap', 'nobr', 'small',
                 'big', 'unicode', 'script', 'font'}
    out = []
    i = 0
    while i < len(text):
        if text.startswith('{{', i):
            depth = 0
            j = i
            while j < len(text):
                if text.startswith('{{', j):
                    depth += 1
                    j += 2
                elif text.startswith('}}', j):
                    depth -= 1
                    j += 2
                    if depth == 0:
                        break
                else:
                    j += 1
            inner = text[i + 2:j - 2]
            parts = inner.split('|')
            name = parts[0].strip().lower()
            if (name in keep_last or name.startswith('lang')) and \
                    len(parts) > 1:
                out.append(_strip_templates(parts[-1]))
            i = j
        else:
            out.append(text[i])
            i += 1
    return ''.join(out)


def clean(text):
    """Plain text of a piece of wikitext: links, bold and italics,
    templates, references, HTML tags and entities resolved; spaces
    collapsed."""
    text = re.sub(r'<ref[^>/]*/>', '', text)
    text = re.sub(r'<ref[^>]*>.*?</ref>', '', text, flags=re.S)
    text = re.sub(r'<!--.*?-->', '', text, flags=re.S)
    text = _strip_templates(text)
    text = re.sub(r'<br\s*/?>', ' ', text, flags=re.I)
    text = re.sub(r'</?[a-zA-Z][^>]*>', '', text)
    text = re.sub(r'\[\[(?:[^|\]]*\|)?([^\]]*)\]\]', r'\1', text)
    text = re.sub(r'\[https?://\S+\s+([^\]]*)\]', r'\1', text)
    text = re.sub(r"'{2,}", '', text)
    text = html.unescape(text)
    return _SPACES.sub(' ', text).strip()


# The pronunciation: an italic group between parentheses at the end.
_PRONUNCIATION = re.compile(r"\(\s*''+([^()]*?)''+\s*\)\s*[.;,]?\s*$")
# Or the whole foreign part being "foreign (pron)" with an italic pron.
_PHRASEBOOK_TEMPLATE = re.compile(
    r'^\{\{\s*(?:phrasebook|phrase)\s*\|(.*)\}\}\s*$', re.I)


# A plain group between parentheses at the end (a romanization after
# text in another script: "Спасибо (spah-SEE-bah)").
_PLAIN_GROUP = re.compile(r'\(([^()]+)\)\s*[.;,]?\s*$')
_LATIN_ONLY = re.compile(r"^[A-Za-z\u00C0-\u024F\u1E00-\u1EFF\s'’.,!?-]+$")


def _non_latin(text):
    return any(char.isalpha() and ord(char) > 0x24F and
               not 0x1E00 <= ord(char) <= 0x1EFF for char in text)


def split_foreign(raw):
    """(translation, pronunciation) of the foreign part of a phrase line:
    the pronunciation is the italic group between parentheses at its end
    (`Olá. (''oh-LAH'')`), or a plain Latin-script group after text in
    another script (`Спасибо (spah-SEE-bah)`)."""
    raw = raw.strip()
    pronunciation = ''
    match = _PRONUNCIATION.search(raw)
    if match:
        pronunciation = clean(match.group(1))
        raw = raw[:match.start()].rstrip()
    else:
        plain = _PLAIN_GROUP.search(raw)
        if plain:
            group = clean(plain.group(1))
            rest = raw[:plain.start()]
            if group and _LATIN_ONLY.match(group) and _non_latin(clean(rest)):
                pronunciation = group
                raw = rest.rstrip()
    return clean(raw), pronunciation


def _definition_split(line):
    """The English and foreign parts of `; English : Foreign`, splitting at
    the first ` : ` (or `:`) outside links and templates."""
    depth = 0
    i = 0
    while i < len(line):
        two = line[i:i + 2]
        if two in ('[[', '{{'):
            depth += 1
            i += 2
            continue
        if two in (']]', '}}'):
            depth = max(0, depth - 1)
            i += 2
            continue
        if line[i] == ':' and depth == 0:
            # Not a time ("10:30") or a URL scheme.
            before = line[i - 1] if i > 0 else ' '
            after = line[i + 1] if i + 1 < len(line) else ' '
            if not (before.isdigit() and after.isdigit()) and \
                    not line[max(0, i - 5):i].lower().endswith('http') and \
                    not line[max(0, i - 6):i].lower().endswith('https'):
                return line[:i], line[i + 1:]
        i += 1
    return line, None


def parse_wikitext(wikitext, max_phrases=MAX_PHRASES):
    """The sections of a Wikivoyage phrasebook's phrase list, as
    [(title, [(english, foreign, pronunciation)])], in the page's order.

    Parsing starts at the "Phrase list" heading when there is one (else at
    the first heading); guide sections (pronunciation, grammar, reading)
    are skipped. Each phrase is a definition-list line `; English :
    Foreign (''pron'')` (the foreign part may be on the next `:` line), a
    bullet `* English : Foreign`, or `{{phrasebook|English|Foreign|Pron}}`.
    """
    lines = wikitext.replace('\r\n', '\n').replace('\r', '\n').split('\n')
    has_list = any(
        (m := _HEADING.match(line)) and clean(m.group(2)).lower() ==
        'phrase list' for line in lines)
    started = not has_list
    sections = []
    title = None
    skipping = False
    phrases = []
    count = 0
    pending = None  # an English term waiting for its `:` line

    def flush():
        nonlocal phrases
        if title is not None and phrases:
            sections.append((title, phrases))
        phrases = []

    def add(english, foreign_raw):
        nonlocal count
        english = clean(english)
        foreign, pronunciation = split_foreign(foreign_raw)
        if not english or not foreign or count >= max_phrases:
            return
        if len(english) > MAX_TEXT or len(foreign) > MAX_TEXT:
            return
        phrases.append((english, foreign, pronunciation[:MAX_TEXT]))
        count += 1

    for line in lines:
        heading = _HEADING.match(line)
        if heading:
            pending = None
            name = clean(heading.group(2))
            if name.lower() == 'phrase list':
                started = True
                flush()
                title = None
                continue
            if not started:
                continue
            flush()
            title = name
            skipping = name.lower() in SKIPPED_SECTIONS
            continue
        if not started or skipping:
            continue
        if title is None:
            title = ''
        stripped = line.strip()
        template = _PHRASEBOOK_TEMPLATE.match(stripped)
        if template:
            parts = [p.strip() for p in template.group(1).split('|')]
            if len(parts) >= 2:
                foreign = parts[1]
                if len(parts) >= 3 and parts[2]:
                    foreign = f"{foreign} (''{parts[2]}'')"
                add(parts[0], foreign)
            pending = None
            continue
        if stripped.startswith(';'):
            english, foreign = _definition_split(stripped[1:])
            if foreign is None:
                pending = english
            else:
                add(english, foreign)
                pending = None
            continue
        if stripped.startswith(':') and pending is not None:
            add(pending, stripped[1:])
            continue
        if stripped.startswith('*'):
            body = stripped.lstrip('*').strip()
            english, foreign = _definition_split(body)
            if foreign is not None:
                add(english, foreign)
            pending = None
            continue
        if stripped:
            pending = None
    flush()
    return sections


# --- Packs -------------------------------------------------------------------


def phrase_id(english, foreign):
    """A stable id of a phrase: the first 12 hex digits of the SHA-256 of
    its English and foreign text (the app's `s:<pack>:<id>`)."""
    digest = hashlib.sha256(f'{english}\x1f{foreign}'.encode('utf-8'))
    return digest.hexdigest()[:12]


def page_url(title, site=SITE):
    return f'https://{site}/wiki/{urllib.parse.quote(title.replace(" ", "_"))}'


def build_pack(wikitext, *, language, title, revision, retrieved,
               name=None, base_language='en', site=SITE, pack_id=None):
    """The pack (a dict) of the phrasebook [title] at [revision]."""
    pack_id = pack_id or (language if base_language == 'en'
                          else f'{language}-{base_language}')
    if not _ID.match(pack_id):
        raise ValueError(f'Invalid pack id {pack_id!r}')
    name = name or PAGES.get(language, (title.replace(' phrasebook', ''),))[0]
    seen = set()
    sections = []
    total = 0
    for section, phrases in parse_wikitext(wikitext):
        items = []
        for english, foreign, pronunciation in phrases:
            pid = phrase_id(english, foreign)
            if pid in seen:
                continue
            seen.add(pid)
            item = {'id': pid, 'text': english, 'translation': foreign}
            if pronunciation:
                item['pronunciation'] = pronunciation
            items.append(item)
        if items:
            sections.append({'title': section, 'phrases': items})
            total += len(items)
    if total == 0:
        raise ValueError(f'No phrases found in {title!r}')
    slug = urllib.parse.quote(title.replace(' ', '_'))
    revision_url = (f'https://{site}/w/index.php?title={slug}&oldid={revision}'
                    if revision else page_url(title, site))
    return {
        'format': FORMAT,
        'formatVersion': FORMAT_VERSION,
        'id': pack_id,
        'language': language,
        'baseLanguage': base_language,
        'name': name,
        'title': title,
        'source': SOURCE,
        'sourceUrl': page_url(title, site),
        'revision': revision,
        'revisionUrl': revision_url,
        'authorsUrl': f'https://{site}/w/index.php?title={slug}&action=history',
        'license': LICENSE,
        'licenseUrl': LICENSE_URL,
        'retrieved': retrieved,
        'attribution': (
            f'From the Wikivoyage article “{title}” (revision {revision}, '
            f'read on {retrieved}), by Wikivoyage contributors, under the '
            f'Creative Commons Attribution-ShareAlike 4.0 licence; shortened '
            f'to its phrase list (each phrase, its translation and '
            f'pronunciation).'),
        'sections': sections,
    }


def pack_bytes(pack):
    """[pack] as a file: sorted, compact UTF-8 JSON, gzip'd with mtime 0
    (the same pack always gives the same bytes)."""
    data = json.dumps(pack, ensure_ascii=False, sort_keys=True,
                      separators=(',', ':')).encode('utf-8')
    out = io.BytesIO()
    with gzip.GzipFile(fileobj=out, mode='wb', compresslevel=9,
                       mtime=0, filename='') as file:
        file.write(data)
    result = out.getvalue()
    if len(result) > MAX_PACK_BYTES:
        raise ValueError(f'Pack of {len(result)} bytes is too large')
    return result


def read_pack(path):
    with open(path, 'rb') as file:
        data = file.read()
    pack = json.loads(gzip.decompress(data).decode('utf-8'))
    if pack.get('format') != FORMAT:
        raise ValueError(f'{path} is not a Mozhi phrasebook')
    return pack, data


def stats(pack, data):
    return {
        'id': pack['id'],
        'language': pack['language'],
        'name': pack['name'],
        'revision': pack['revision'],
        'sections': len(pack['sections']),
        'phrases': sum(len(s['phrases']) for s in pack['sections']),
        'pronunciations': sum(
            1 for s in pack['sections'] for p in s['phrases']
            if p.get('pronunciation')),
        'size': len(data),
        'sha256': hashlib.sha256(data).hexdigest(),
    }


# --- MediaWiki API -----------------------------------------------------------


def api_url(title=None, revision=None, site=SITE):
    """The API request for the wikitext of [title] (latest) or of
    [revision]."""
    query = {
        'action': 'query', 'prop': 'revisions',
        'rvprop': 'ids|timestamp|content', 'rvslots': 'main',
        'format': 'json', 'formatversion': '2',
    }
    if revision:
        query['revids'] = str(revision)
    else:
        query['titles'] = title
    return f'https://{site}/w/api.php?{urllib.parse.urlencode(query)}'


def parse_api_response(response):
    """{title, revision, timestamp, wikitext} of an API response (see
    [api_url]). Raises ValueError for a missing page or revision."""
    pages = response.get('query', {}).get('pages', [])
    for page in pages:
        if page.get('missing') or not page.get('revisions'):
            continue
        revision = page['revisions'][0]
        slots = revision.get('slots', {})
        content = slots.get('main', {}).get('content')
        if content is None:
            content = revision.get('content')
        if content is None:
            continue
        return {
            'title': page['title'],
            'revision': revision['revid'],
            'timestamp': revision.get('timestamp', ''),
            'wikitext': content,
        }
    raise ValueError('No such page or revision')


def fetch(language, revision=None, site=SITE, opener=None):
    """The page of [language] (see PAGES) at [revision] (default: the
    latest) from the MediaWiki API."""
    _, title = PAGES[language]
    request = urllib.request.Request(
        api_url(title, revision, site), headers={'User-Agent': USER_AGENT})
    open_url = opener or urllib.request.urlopen
    with open_url(request, timeout=60) as response:
        page = parse_api_response(json.load(response))
    if revision and page['revision'] != int(revision):
        raise ValueError(f'Got revision {page["revision"]}, not {revision}')
    if not revision and page['title'] != title:
        raise ValueError(f'Got {page["title"]!r}, not {title!r}')
    return page


# --- Catalogue ---------------------------------------------------------------


def catalog(paths, release, base_url, source=None):
    """phrasebook_catalog.json for the packs at [paths] (the app pins their
    sizes and SHA-256)."""
    packs = []
    for path in paths:
        pack, data = read_pack(path)
        file = os.path.basename(path)
        if file != f'{pack["id"]}{PACK_EXTENSION}':
            raise ValueError(f'{path} should be named {pack["id"]}'
                             f'{PACK_EXTENSION}')
        info = stats(pack, data)
        packs.append({
            'id': pack['id'],
            'language': pack['language'],
            'baseLanguage': pack['baseLanguage'],
            'name': pack['name'],
            'file': file,
            'url': f'{base_url.rstrip("/")}/{file}',
            'size': info['size'],
            'sha256': info['sha256'],
            'phrases': info['phrases'],
            'revision': pack['revision'],
            'sourceUrl': pack['sourceUrl'],
            'license': pack['license'],
        })
    packs.sort(key=lambda p: p['name'])
    ids = [p['id'] for p in packs]
    if len(set(ids)) != len(ids):
        raise ValueError('Duplicate pack ids')
    result = {'schemaVersion': 1, 'release': release}
    if source:
        result['source'] = source
    result['packs'] = packs
    return result


def dart_catalog(catalog_json):
    """lib/phrasebook/data/starter_catalog_data.dart for [catalog_json]."""
    text = json.dumps(catalog_json, ensure_ascii=False, indent=2)
    if "'''" in text:
        raise ValueError("The catalogue can't contain '''")
    text = text.replace('\\', '\\\\').replace('$', '\\$')
    return (
        '// Generated by `python3 tool/phrasebooks.py dart`: the starter\n'
        '// phrasebooks of the release named below, with their sizes and\n'
        '// SHA-256 (see docs/phrasebook.md). Do not edit by hand.\n'
        '\n'
        '/// The bundled starter phrasebook catalogue (`phrasebook_catalog.json`'
        ' of\n/// the latest `phrasebooks-<date>` release).\n'
        f"const starterCatalogJson = '''\n{text}\n''';\n")


# --- Command line ------------------------------------------------------------


def _read_page(path, args):
    """{title, revision, wikitext} from a `fetch` JSON or a wikitext file
    (then --title and --revision say what it is)."""
    with open(path, encoding='utf-8') as file:
        text = file.read()
    if path.endswith('.json'):
        page = json.loads(text)
        return page['title'], page['revision'], page['wikitext']
    if not args.title:
        raise SystemExit('--title is needed with a wikitext file')
    return args.title, args.revision or 0, text


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)

    fetch_cmd = commands.add_parser('fetch', help='page wikitext from the API')
    fetch_cmd.add_argument('language')
    fetch_cmd.add_argument('--revision', type=int)
    fetch_cmd.add_argument('--site', default=SITE)
    fetch_cmd.add_argument('--output', required=True)

    build = commands.add_parser('build', help='page -> pack')
    build.add_argument('input', help='a `fetch` .json or a .wikitext file')
    build.add_argument('--language', required=True)
    build.add_argument('--name')
    build.add_argument('--base-language', default='en')
    build.add_argument('--title')
    build.add_argument('--revision', type=int)
    build.add_argument('--retrieved', default='')
    build.add_argument('--site', default=SITE)
    build.add_argument('--output', required=True)
    build.add_argument('--stats')

    cat = commands.add_parser('catalog', help='packs -> phrasebook_catalog.json')
    cat.add_argument('packs', nargs='+')
    cat.add_argument('--release', required=True)
    cat.add_argument('--base-url', required=True)
    cat.add_argument('--source')

    dart = commands.add_parser('dart', help='catalogue -> Dart constant')
    dart.add_argument('catalog')

    commands.add_parser('pages', help='languages and their Wikivoyage pages')

    dump = commands.add_parser('dump', help='print a pack')
    dump.add_argument('pack')

    args = parser.parse_args(argv)
    if args.command == 'fetch':
        if args.language not in PAGES:
            raise SystemExit(f'No Wikivoyage page for {args.language!r}')
        page = fetch(args.language, args.revision, args.site)
        with open(args.output, 'w', encoding='utf-8') as file:
            json.dump(page, file, ensure_ascii=False, indent=1)
        print(f'{page["title"]} revision {page["revision"]} '
              f'({len(page["wikitext"]):,} characters)', file=sys.stderr)
    elif args.command == 'build':
        title, revision, wikitext = _read_page(args.input, args)
        pack = build_pack(
            wikitext, language=args.language, title=title, revision=revision,
            retrieved=args.retrieved, name=args.name,
            base_language=args.base_language, site=args.site)
        data = pack_bytes(pack)
        with open(args.output, 'wb') as file:
            file.write(data)
        info = stats(pack, data)
        if args.stats:
            with open(args.stats, 'w', encoding='utf-8') as file:
                json.dump(info, file, indent=1)
        print(f'{info["name"]}: {info["phrases"]} phrases in '
              f'{info["sections"]} sections ({info["pronunciations"]} with '
              f'pronunciation), {info["size"]:,} bytes, SHA-256 '
              f'{info["sha256"]}', file=sys.stderr)
    elif args.command == 'catalog':
        json.dump(catalog(args.packs, args.release, args.base_url,
                          args.source),
                  sys.stdout, ensure_ascii=False, indent=2)
        sys.stdout.write('\n')
    elif args.command == 'dart':
        with open(args.catalog, encoding='utf-8') as file:
            sys.stdout.write(dart_catalog(json.load(file)))
    elif args.command == 'pages':
        for code, (name, title) in sorted(PAGES.items()):
            print(f'{code}\t{name}\t{page_url(title)}')
    elif args.command == 'dump':
        pack, data = read_pack(args.pack)
        print(json.dumps(stats(pack, data), indent=1))
        for section in pack['sections']:
            print(f'== {section["title"]} ({len(section["phrases"])})')
            for phrase in section['phrases'][:5]:
                pron = phrase.get('pronunciation')
                print(f'  {phrase["text"]} : {phrase["translation"]}'
                      + (f' ({pron})' if pron else ''))
    return 0


if __name__ == '__main__':
    sys.exit(main())
