#!/usr/bin/env python3
"""Fetches the offline models of one language for the on-device web spec.

Usage: python3 e2e/fetch_models.py <language> <directory>

Downloads both directions of <language> (e.g. "de": de-en and en-de, 51 MB)
from the URLs in packages/bergamot_translator/assets/catalog.json into
<directory>/bergamot/<pair>/<version>/<file>.gz, the layout of a model
mirror (packages/bergamot_translator/lib/src/model_source.dart), and checks
each file's size and SHA-256 against the catalog. Files already there and
intact are kept, so a cached directory costs nothing.

tests/offline_engine.spec.js serves them to the app instead of Mozilla's
bucket or the same-origin mirror ($E2E_MODELS_DIR); the spec is skipped
without them. Standard library only.
"""
import hashlib
import json
import os
import shutil
import sys
import tempfile
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(
    ROOT, 'packages', 'bergamot_translator', 'assets', 'catalog.json')


def sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as file:
        for chunk in iter(lambda: file.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def intact(path, entry):
    return (os.path.isfile(path) and os.path.getsize(path) == entry['size']
            and sha256(path) == entry['sha256'])


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    language, directory = sys.argv[1], sys.argv[2]
    with open(CATALOG, encoding='utf-8') as file:
        models = json.load(file)['models']
    chosen = [m for m in models
              if language in (m['source'], m['target'])
              and 'en' in (m['source'], m['target'])]
    if not chosen:
        sys.exit(f'No models for {language!r} in the catalog')
    total = 0
    for model in chosen:
        pair = f"{model['source']}-{model['target']}"
        folder = os.path.join(directory, 'bergamot', pair, model['version'])
        os.makedirs(folder, exist_ok=True)
        for entry in model['files'].values():
            name = entry['url'].rsplit('/', 1)[-1]
            path = os.path.join(folder, name)
            total += entry['size']
            if intact(path, entry):
                continue
            with tempfile.NamedTemporaryFile(dir=folder, delete=False) as part:
                with urllib.request.urlopen(entry['url'], timeout=120) as response:
                    shutil.copyfileobj(response, part)
            if not intact(part.name, entry):
                os.unlink(part.name)
                sys.exit(f'{entry["url"]}: size or SHA-256 does not match the catalog')
            os.replace(part.name, path)
            print(f'{pair}/{name}: {entry["size"]} bytes')
    print(f'{language}: {len(chosen)} models, {total} bytes in {directory}')


if __name__ == '__main__':
    main()
