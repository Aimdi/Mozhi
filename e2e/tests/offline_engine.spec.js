// On-device translation in the browser: Mozilla's Bergamot engine compiled
// to WebAssembly (web/bergamot/, built by
// packages/bergamot_translator/tool/build_wasm.sh) with the language packs
// in the browser's private storage (OPFS).
//
// Needs the engine in the web build (build/web*/bergamot/
// bergamot-translator.{js,wasm}) and the real German models in
// $E2E_MODELS_DIR (51 MB: `python3 fetch_models.py de <dir>`, which CI
// caches); skipped otherwise. The models are served to the app from that
// directory whatever host it asks (its same-origin mirror or Mozilla's
// bucket), then the host is cut off: everything after the download runs
// without it, also after a reload.
const fs = require('node:fs');
const path = require('node:path');
const { expect } = require('@playwright/test');
const {
  collectPageErrors,
  copiedTranslation,
  fillField,
  openApp,
  seedSettings,
  test,
  typeSource,
} = require('./helpers');

const MODELS_DIR = process.env.E2E_MODELS_DIR;
const WEB_DIR = path.resolve(
  __dirname,
  '..',
  process.env.E2E_WEB_DIR || path.join('..', 'build', 'web'),
);

/** The mirror-layout file (bergamot/<pair>/<version>/<name>.gz) of a URL. */
function modelFile(url) {
  const { pathname } = new URL(url);
  const parts = pathname.split('/').filter(Boolean);
  // .../bergamot/<pair>/<version>/<name>.gz (a mirror) or
  // .../models/<pair>/<version>/exported/<name>.gz (Mozilla's bucket).
  const name = parts[parts.length - 1];
  const exported = parts[parts.length - 2] === 'exported';
  const version = parts[parts.length - (exported ? 3 : 2)];
  const pair = parts[parts.length - (exported ? 4 : 3)];
  return path.join(MODELS_DIR, 'bergamot', pair, version, name);
}

const MODEL_URLS = /\/bergamot\/[a-z_]+-[a-z_]+\/|storage\.googleapis\.com\//;

/** Serves the model files from MODELS_DIR; returns the requested URLs. */
async function serveModels(context) {
  const requested = [];
  await context.route(MODEL_URLS, async (route) => {
    const url = route.request().url();
    if (url.endsWith('.js') || url.endsWith('.wasm')) return route.continue();
    requested.push(url);
    const file = modelFile(url);
    if (!fs.existsSync(file)) return route.fulfill({ status: 404 });
    return route.fulfill({
      status: 200,
      body: fs.readFileSync(file),
      headers: {
        'content-type': 'application/octet-stream',
        'access-control-allow-origin': '*',
      },
    });
  });
  return requested;
}

/** Cuts the model host off: every model request fails from now on. */
async function cutModelHost(context) {
  await context.unrouteAll({ behavior: 'ignoreErrors' });
  const attempts = [];
  await context.route(MODEL_URLS, (route) => {
    const url = route.request().url();
    if (url.endsWith('.js') || url.endsWith('.wasm')) return route.continue();
    attempts.push(url);
    return route.abort('connectionrefused');
  });
  return attempts;
}

test.describe('on-device translation in the browser', () => {
  test.skip(
    !MODELS_DIR || !fs.existsSync(path.join(MODELS_DIR, 'bergamot')),
    'Set E2E_MODELS_DIR (python3 fetch_models.py de <dir>)',
  );
  test.skip(
    !fs.existsSync(path.join(WEB_DIR, 'bergamot', 'bergamot-translator.wasm')),
    'The web build has no Bergamot WASM engine (tool/build_wasm.sh)',
  );
  // A download of 51 MB plus the engine's first start.
  test.setTimeout(180_000);

  test('downloads German, then translates with the model host cut off', async ({
    page,
    context,
  }) => {
    await seedSettings(page, 'settings-ai', {
      engineId: 'offline:mlkit',
      source: { code: 'en', name: 'English' },
      target: { code: 'de', name: 'German' },
    });
    const errors = collectPageErrors(page);
    const requested = await serveModels(context);

    // The offline languages page offers the packs, with sizes.
    await openApp(page, '/settings/offline');
    await fillField(
      page.getByRole('searchbox', { name: 'Search languages' }),
      'German',
    );
    const download = page.getByRole('group', { name: /^Download German/ });
    await expect(download).toHaveAccessibleName(/48\.8 MB download/);
    await download.getByRole('button', { name: 'Download' }).click();
    // The snack bar (its text is also announced to screen readers).
    await expect(
      page.locator('span', { hasText: 'German is ready for offline use' }),
    ).toBeVisible({ timeout: 120_000 });
    await expect(
      page.getByRole('group', { name: /^Delete German .*on this device/ }),
    ).toBeVisible();
    // Both directions, three files each, each fetched once.
    expect(requested).toHaveLength(6);

    // From here on the model host is gone.
    const attempts = await cutModelHost(context);
    await openApp(page, '/translate');
    await typeSource(page, 'Hello, how are you?');
    await expect
      .poll(() => copiedTranslation(page), { timeout: 60_000 })
      .toBe('Hallo, wie geht es dir?');

    // After a reload the packs are still there: nothing is downloaded.
    await page.reload();
    await openApp(page, '/translate');
    await typeSource(page, 'The weather is nice today.');
    await expect
      .poll(() => copiedTranslation(page), { timeout: 60_000 })
      .toBe('Das Wetter ist heute schön.');
    expect(attempts).toEqual([]);
    expect(errors).toEqual([]);
  });
  test('detects the language on the device (CLD2) for an automatic source', async ({
    page,
    context,
  }) => {
    await seedSettings(page, 'settings-ai', {
      engineId: 'offline:mlkit',
      source: { code: 'auto', name: 'Detect language' },
      target: { code: 'en', name: 'English' },
    });
    const errors = collectPageErrors(page);
    await serveModels(context);
    await openApp(page, '/settings/offline');
    await fillField(
      page.getByRole('searchbox', { name: 'Search languages' }),
      'German',
    );
    await page
      .getByRole('group', { name: /^Download German/ })
      .getByRole('button', { name: 'Download' })
      .click();
    await expect(
      page.getByRole('group', { name: /^Delete German .*on this device/ }),
    ).toBeVisible({ timeout: 120_000 });

    const attempts = await cutModelHost(context);
    await openApp(page, '/translate');
    await typeSource(page, 'Guten Morgen, wie geht es dir?');
    await expect
      .poll(() => copiedTranslation(page), { timeout: 60_000 })
      .toBe('Good morning, how are you?');
    expect(attempts).toEqual([]);
    expect(errors).toEqual([]);
  });
});
