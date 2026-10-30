// The web app with no network: the app shell (web/mozhi_sw.js, which keeps
// the files tool/web_shell_manifest.py lists) lets it open again offline
// once it has been opened, and "Import from files" installs the offline
// language packs into the browser's private storage without the network.
//
// Needs a web build with the shell's manifest (tool/web_shell_manifest.py),
// the Bergamot engine in it (bergamot/bergamot-translator.wasm) and the
// real German models in $E2E_MODELS_DIR (`python3 fetch_models.py de
// <dir>`); skipped otherwise. The other specs run with service workers
// blocked (playwright.config.js); these allow them.

// The worker's own requests show in the context's network events and obey
// its offline switch only with this, read when the worker starts.
process.env.PW_EXPERIMENTAL_SERVICE_WORKER_NETWORK_EVENTS = '1';

const { execFileSync, spawn } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { expect } = require('@playwright/test');
const {
  collectPageErrors,
  copiedTranslation,
  openApp,
  seedSettings,
  skipWithoutOnDeviceEngine,
  test,
  typeSource,
  waitForSemantics,
} = require('./helpers');

const TOOL = path.join(__dirname, '..', '..', 'tool', 'web_shell_manifest.py');
/** A copy of the build that the update test changes, served here. */
const UPDATE_PORT = Number(process.env.E2E_APP_PORT || 8080) + 3;

const MODELS_DIR = process.env.E2E_MODELS_DIR;
const WEB_DIR = path.resolve(
  __dirname,
  '..',
  process.env.E2E_WEB_DIR || path.join('..', 'build', 'web'),
);

/** Model downloads (a mirror's bergamot/<pair>/ or Mozilla's bucket). */
const MODEL_URLS = /\/bergamot\/[a-z_]+-[a-z_]+\/|storage\.googleapis\.com\//;

/** Every published model file of $E2E_MODELS_DIR (both directions). */
function modelFiles() {
  const files = [];
  const visit = (folder) => {
    for (const entry of fs.readdirSync(folder, { withFileTypes: true })) {
      const file = path.join(folder, entry.name);
      if (entry.isDirectory()) visit(file);
      else if (entry.name.endsWith('.gz')) files.push(file);
    }
  };
  visit(path.join(MODELS_DIR, 'bergamot'));
  return files.sort();
}

/** Fails every model download: imports and the shell need none. */
async function refuseModelDownloads(context) {
  const attempts = [];
  await context.route(MODEL_URLS, (route) => {
    const url = route.request().url();
    if (url.endsWith('.js') || url.endsWith('.wasm')) return route.continue();
    attempts.push(url);
    return route.abort('connectionrefused');
  });
  return attempts;
}

/**
 * Settings > Translation engines > Offline languages > Import from files,
 * with the German models: both directions are installed.
 */
async function importGerman(page) {
  await openApp(page, '/settings/offline');
  await skipWithoutOnDeviceEngine(page);
  const chooser = page.waitForEvent('filechooser');
  await page.getByRole('button', { name: /^Import from files/ }).click();
  await (await chooser).setFiles(modelFiles());
  const dialog = page.getByRole('alertdialog');
  await expect(dialog.getByText('Models imported')).toBeVisible({
    timeout: 120_000,
  });
  // The language names are bidi isolates.
  await expect(dialog.getByText(/^Installed \W?German\W? → /)).toBeVisible();
  await expect(dialog.getByText(/^Installed \W?English\W? → /)).toBeVisible();
  await dialog.getByRole('button', { name: 'Close' }).click();
  await expect(
    page.getByRole('button', { name: /^Delete German .*on this device/ }),
  ).toBeVisible();
}

/** The app's service worker, as the page sees it. */
function shellWorker(page) {
  return page.evaluate(async () => {
    const registration = await navigator.serviceWorker.getRegistration();
    return {
      active: registration?.active?.state ?? null,
      script: registration?.active?.scriptURL ?? null,
      caches: (await caches.keys()).filter((name) =>
        name.startsWith('mozhi-shell:'),
      ),
    };
  });
}

/** The status the shell's switch reads out (its subtitle). */
const READY = /Opens in this browser without a network/;

/** What the switch says in a browser that does not let the app keep itself. */
const UNAVAILABLE = /This browser can.t keep the app/;

/**
 * Settings > General: "Keep the web app for offline use" and its status.
 * Skips the test where the browser refuses the app's service worker (the
 * switch then says so, which is what such a browser should show).
 */
async function openShellSetting(page) {
  await openApp(page, '/settings/general?row=offline_app_shell');
  const setting = page.getByRole('switch', {
    name: /^Keep the web app for offline use/,
  });
  await expect(setting).toHaveAccessibleName(
    new RegExp(`${READY.source}|${UNAVAILABLE.source}`),
    { timeout: 120_000 },
  );
  test.skip(
    (await page.getByRole('switch', { name: UNAVAILABLE }).count()) > 0,
    'This browser does not let the app register its service worker here',
  );
  return setting;
}

test.describe('the web app with no network', () => {
  test.skip(
    !MODELS_DIR || !fs.existsSync(path.join(MODELS_DIR, 'bergamot')),
    'Set E2E_MODELS_DIR (python3 fetch_models.py de <dir>)',
  );
  test.skip(
    !fs.existsSync(path.join(WEB_DIR, 'bergamot', 'bergamot-translator.wasm')),
    'The web build has no Bergamot WASM engine (tool/build_wasm.sh)',
  );
  test.skip(
    !fs.existsSync(path.join(WEB_DIR, 'mozhi_sw_manifest.json')),
    'The web build has no app shell manifest (tool/web_shell_manifest.py)',
  );
  test.use({ serviceWorkers: 'allow' });
  // Importing 51 MB, the shell's 30 MB and the engine's first start.
  test.setTimeout(240_000);

  test.beforeEach(async ({ page }) => {
    await seedSettings(page, 'settings-ai', {
      engineId: 'offline:mlkit',
      source: { code: 'en', name: 'English' },
      target: { code: 'de', name: 'German' },
    });
  });

  test('imports the language packs from files, without the network', async ({
    page,
    context,
  }) => {
    const errors = collectPageErrors(page);
    const attempts = await refuseModelDownloads(context);

    await importGerman(page);
    await openApp(page, '/translate');
    await typeSource(page, 'Hello, how are you?');
    await expect
      .poll(() => copiedTranslation(page), { timeout: 60_000 })
      .toBe('Hallo, wie geht es dir?');
    expect(attempts).toEqual([]);
    expect(errors).toEqual([]);
  });

  test('opens and translates offline once it was opened', async ({
    page,
    context,
    browserName,
  }) => {
    const errors = collectPageErrors(page);
    await refuseModelDownloads(context);
    await importGerman(page);

    // The shell keeps the build's files.
    const setting = await openShellSetting(page);
    await expect(setting).toBeChecked();
    await expect(setting).toHaveAccessibleName(READY, { timeout: 120_000 });
    const worker = await shellWorker(page);
    expect(worker.active).toBe('activated');
    expect(worker.script).toMatch(/\/mozhi_sw\.js$/);
    expect(worker.caches).toHaveLength(1);

    // No network at all from here: the page, the worker and the engine.
    const served = [];
    page.on('response', (response) => {
      if (new URL(response.url()).port === new URL(page.url()).port) {
        served.push(response.fromServiceWorker());
      }
    });
    // Firefox's offline mode refuses even the navigations a service
    // worker answers (its "Offline mode" page), so there every request
    // that reaches the network fails instead: a reload the shell does not
    // answer fails just the same.
    if (browserName === 'firefox') {
      await context.route('**/*', (route) =>
        route.abort('internetdisconnected'),
      );
    } else {
      await context.setOffline(true);
    }
    await page.reload();
    await waitForSemantics(page);
    await openApp(page, '/translate');
    await typeSource(page, 'The weather is nice today.');
    await expect
      .poll(() => copiedTranslation(page), { timeout: 60_000 })
      .toBe('Das Wetter ist heute schön.');
    // Everything of the app came from the shell (Playwright tells which
    // responses a service worker made in Chromium only).
    if (browserName === 'chromium') {
      expect(served.length).toBeGreaterThan(5);
      expect(served.every(Boolean)).toBe(true);
    }
    await context.setOffline(false);
    await context.unrouteAll({ behavior: 'ignoreErrors' });
    expect(errors).toEqual([]);
  });

  test('turning it off removes the worker and what it kept', async ({
    page,
  }) => {
    const errors = collectPageErrors(page);
    const setting = await openShellSetting(page);
    await expect(setting).toHaveAccessibleName(READY, { timeout: 120_000 });

    await setting.click();
    await expect(setting).not.toBeChecked();
    await expect(setting).toHaveAccessibleName(
      /The app needs a network to open/,
    );
    await expect
      .poll(async () => {
        const worker = await shellWorker(page);
        const registrations = await page.evaluate(
          async () => (await navigator.serviceWorker.getRegistrations()).length,
        );
        return { registrations, caches: worker.caches.length };
      })
      .toEqual({ registrations: 0, caches: 0 });

    // On again: kept again.
    await setting.click();
    await expect(setting).toHaveAccessibleName(READY, { timeout: 120_000 });
    expect(errors).toEqual([]);
  });

  test.describe('an update', () => {
    let site;
    let server;

    test.beforeAll(async () => {
      site = fs.mkdtempSync(path.join(os.tmpdir(), 'mozhi-shell-'));
      fs.cpSync(WEB_DIR, site, { recursive: true });
      server = spawn(
        'python3',
        ['-m', 'http.server', String(UPDATE_PORT), '--bind', '127.0.0.1'],
        { cwd: site, stdio: 'ignore' },
      );
      await expect
        .poll(
          async () => {
            try {
              return (await fetch(`http://127.0.0.1:${UPDATE_PORT}/`)).status;
            } catch (_) {
              return 0;
            }
          },
          { timeout: 20_000 },
        )
        .toBe(200);
    });

    test.afterAll(() => {
      server?.kill();
      if (site) fs.rmSync(site, { recursive: true, force: true });
    });

    test('is kept in the background, then Reload swaps it in', async ({
      page,
      browserName,
    }) => {
      const errors = collectPageErrors(page);
      const origin = `http://127.0.0.1:${UPDATE_PORT}`;
      await page.goto(`${origin}/#/translate`);
      await waitForSemantics(page);
      test.skip(
        !(await page.evaluate(() => isSecureContext && 'serviceWorker' in navigator)),
        'This browser has no service workers here',
      );
      await expect
        .poll(async () => (await shellWorker(page)).active, {
          timeout: 120_000,
        })
        .toBe('activated');
      const first = await shellWorker(page);

      // A new build on the server: one file changed, listed again. The
      // next start finds it and keeps it next to the running version.
      fs.appendFileSync(path.join(site, 'version.json'), ' ');
      execFileSync('python3', [TOOL, site]);
      await page.reload();
      await waitForSemantics(page);
      await expect
        .poll(async () => (await shellWorker(page)).caches, {
          timeout: 120_000,
        })
        .toHaveLength(2);
      // The app says so: the "Update ready" snack bar (its text is not
      // always in the page's semantics tree yet, so the setting, which
      // offers Reload too, is what is checked here).
      await page.goto(`${origin}/#/settings/general?row=offline_app_shell`);
      await waitForSemantics(page);
      const setting = page.getByRole('switch', {
        name: /^Keep the web app for offline use/,
      });
      await expect(setting).toHaveAccessibleName(
        /A new version is ready\. Reload to use it\./,
        { timeout: 60_000 },
      );

      // Reload: the new version takes over and the page reloads with it.
      await Promise.all([
        page.waitForEvent('load'),
        page.getByRole('button', { name: 'Reload' }).last().click(),
      ]);
      await waitForSemantics(page);
      await expect
        .poll(async () => (await shellWorker(page)).caches, {
          timeout: 60_000,
        })
        .toHaveLength(1);
      // The new worker's activate step only drops the old cache (done:
      // one cache left). WebKit's page side can keep reporting it as
      // `activating` for longer than this test waits (in one of two CI
      // runs of the same build), so there either state is accepted; the
      // checks below are what tells that the new version took over.
      const activeState =
        browserName === 'webkit' ? /^activat(ed|ing)$/ : /^activated$/;
      await expect
        .poll(async () => (await shellWorker(page)).active, {
          timeout: 60_000,
        })
        .toMatch(activeState);
      const after = await shellWorker(page);
      expect(after.caches).not.toEqual(first.caches);
      await expect(setting).toHaveAccessibleName(READY, { timeout: 60_000 });
      expect(errors).toEqual([]);
    });
  });
});
