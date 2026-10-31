// Shared helpers for the Mozhi web E2E specs.
const fs = require('node:fs');
const path = require('node:path');
const { test: base, expect } = require('@playwright/test');

const MOCK_PORT = Number(process.env.E2E_MOCK_PORT || 8787);
const FIXTURES = path.join(__dirname, '..', 'fixtures');

/** Reads a settings fixture, pointing its URLs at the mock server's port. */
function loadSettings(name, overrides = {}) {
  const raw = fs
    .readFileSync(path.join(FIXTURES, `${name}.json`), 'utf8')
    .replaceAll('http://127.0.0.1:8787', `http://127.0.0.1:${MOCK_PORT}`);
  return { ...JSON.parse(raw), ...overrides };
}

/**
 * Seeds the app's settings before any page script runs.
 *
 * shared_preferences (SharedPreferencesAsync) on the web keeps each key
 * unprefixed in localStorage with a JSON-encoded value; the settings
 * themselves are a JSON string, so the stored value is encoded twice.
 */
async function seedSettings(page, name, overrides = {}) {
  const settings = loadSettings(name, overrides);
  await page.addInitScript((value) => {
    if (sessionStorage.getItem('e2e.seeded')) return;
    localStorage.clear();
    localStorage.setItem('settings.v1', JSON.stringify(JSON.stringify(value)));
    sessionStorage.setItem('e2e.seeded', '1');
  }, settings);
}

/**
 * Records what the page writes to the clipboard (in `window`, next to the
 * real write, which still happens): [readClipboard] falls back to it where
 * the browser does not let a test read the clipboard back.
 */
function recordClipboardWrites() {
  const clipboard = navigator.clipboard;
  if (!clipboard || typeof clipboard.writeText !== 'function') return;
  const writeText = clipboard.writeText.bind(clipboard);
  window.__mozhiE2eClipboard = null;
  clipboard.writeText = (text) => {
    window.__mozhiE2eClipboard = String(text);
    return writeText(text);
  };
}

/**
 * Reports Content Security Policy violations to the console in one format:
 * Chromium and WebKit log them as "... Content Security Policy ...",
 * Firefox as "Content-Security-Policy: ...", and some browsers not at all
 * for every kind (the event always fires).
 */
function reportCspViolations() {
  document.addEventListener('securitypolicyviolation', (event) => {
    console.error(
      `Content Security Policy violation: ${event.violatedDirective} ` +
        `blocked ${event.blockedURI || 'inline'}`,
    );
  });
}

/** A console error about the Content Security Policy, in any browser. */
const CSP_MESSAGE = /Content[- ]Security[- ]Policy/i;

/**
 * The Playwright `test` with an automatic check that fails any test whose
 * page logged a Content Security Policy violation (web/index.html sets a
 * strict CSP; a blocked script, font or request shows up as a console
 * error mentioning it, and as a `securitypolicyviolation` event, which
 * [reportCspViolations] logs). Every page also records its clipboard
 * writes ([recordClipboardWrites]). Specs import `test` from here.
 */
const test = base.extend({
  cspViolations: [
    async ({ page }, use) => {
      const violations = [];
      page.on('console', (message) => {
        if (message.type() === 'error' && CSP_MESSAGE.test(message.text())) {
          violations.push(message.text());
        }
      });
      await page.addInitScript(reportCspViolations);
      await page.addInitScript(recordClipboardWrites);
      await use(violations);
      if (violations.length > 0) {
        throw new Error(
          `Content Security Policy violations:\n${violations.join('\n')}`,
        );
      }
    },
    { auto: true },
  ],
});

/** Collects uncaught page errors, to assert on at the end of a test. */
function collectPageErrors(page) {
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  return errors;
}

/** Records every request the page sends to the mock AI provider. */
function recordAiRequests(page) {
  const requests = [];
  page.on('request', (request) => {
    if (request.url().includes('/v1/chat/completions')) {
      requests.push(request.postDataJSON?.() ?? null);
    }
  });
  return requests;
}

/**
 * Waits until the app is up with its semantics tree: widgets are exposed as
 * ARIA roles and labels, which the specs find them by. The app turns the
 * tree on at startup on the web (lib/bootstrap.dart, `ensureSemantics`), so
 * nothing needs to activate Flutter's hidden "Enable accessibility" button
 * any more: the engine removes it once the tree is there.
 */
async function waitForSemantics(page) {
  await expect(page.locator('flt-semantics').first()).toBeAttached({
    timeout: 60_000,
  });
}

/**
 * Opens the app at [location] (a router location such as `/translate` or
 * `/settings/usage?x=1`; the app uses the hash URL strategy) and waits for
 * its semantics tree.
 */
async function openApp(page, location = '/translate') {
  await page.goto(`/#${location}`);
  await waitForSemantics(page);
}

/** The translate screen's text input. */
function sourceInput(page) {
  return page.getByRole('textbox', { name: 'Text to translate' });
}

/**
 * Empties the clipboard (and what [recordClipboardWrites] recorded), so
 * that the next [readClipboard] shows only what the app copies after this.
 * A browser that allows writing only from a user gesture (WebKit) keeps
 * its contents; the record is emptied anyway.
 */
async function clearClipboard(page) {
  await page.evaluate(async () => {
    window.__mozhiE2eClipboard = null;
    try {
      await navigator.clipboard.writeText('');
    } catch (_) {
      // Not without a user gesture here.
    }
    window.__mozhiE2eClipboard = null;
  });
}

/**
 * The text on the clipboard: read from the clipboard itself where the
 * browser lets the test read it, else what the page last wrote to it
 * ([recordClipboardWrites]; '' when nothing since [clearClipboard]).
 */
function readClipboard(page) {
  return page.evaluate(async () => {
    const recorded = window.__mozhiE2eClipboard;
    try {
      const text = await navigator.clipboard.readText();
      // A clipboard the test could not empty still holds an older text.
      if (recorded == null || text === recorded) return text;
    } catch (_) {
      // Reading is not allowed here.
    }
    return recorded ?? '';
  });
}

/**
 * The text of the current translation.
 *
 * Reads it the way a user takes it: presses the result card's Copy button
 * and reads the clipboard ([readClipboard]; the projects in
 * playwright.config.js allow it as each browser can). [scope] narrows the
 * search for the button (e.g. a history entry); [button] is its name (e.g.
 * the proofread result's "Copy corrected text").
 */
async function copiedTranslation(
  page,
  scope = page,
  button = /^Copy( Copy)?$/,
) {
  await clearClipboard(page);
  // While the pointer rests on the button its tooltip ("Copy") is merged
  // into the label; move the pointer away afterwards so the next call
  // finds the plain label again.
  await scope.getByRole('button', { name: button }).click();
  await page.mouse.move(0, 0);
  return readClipboard(page);
}

/** [text] with the characters a regular expression gives a meaning escaped. */
function escapeRegExp(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/**
 * Focuses the text field [locator] and replaces its text with [text].
 *
 * The app must have focused the field (its DOM element then holds the
 * editing session) before the text goes in, so this waits for that after
 * the click: a click that lands on something above the field (a snack bar)
 * or on an element the screen is about to replace is tried again. With
 * [refocus] (a retry after the app missed the text), focus first moves on
 * with Tab: a field that kept focus while its element was replaced (the
 * screen switched layouts) keeps a stale editing session that never
 * reaches the app, and only a new focus starts a fresh one.
 */
async function fillField(locator, text, { refocus = false } = {}) {
  const page = locator.page();
  let attempt = 0;
  await expect(async () => {
    if (refocus || attempt > 0) await page.keyboard.press('Tab');
    attempt++;
    // Near the top left corner, not in the middle: a field's box includes
    // its helper text, which takes the click when it wraps to more lines
    // than the field is tall (the monospaced Terminal look).
    await locator.click({ position: { x: 16, y: 16 } });
    await expect(locator).toBeFocused({ timeout: 2_000 });
    await locator.fill(text);
    await expect(locator).toHaveValue(text, { timeout: 2_000 });
  }).toPass({ timeout: 20_000 });
}

/**
 * Types [text] into the translate screen's input and waits until the app
 * has it: the character count under the field is built from the app's
 * state. The field's DOM value alone can be ahead of the app on a slow
 * machine or after a stale editing session (see [fillField]; the app then
 * never sees the text, and a Translate pressed then would translate the
 * previous one), so the text is filled again, after a fresh focus, until
 * the count shows it.
 */
async function typeSource(page, text) {
  if (text.trim().length === 0) {
    await fillField(sourceInput(page), text);
    return;
  }
  // Grapheme clusters, as Dart's `characters.length` counts them.
  const count = [...new Intl.Segmenter().segment(text)].length;
  const label = page.getByText(
    count === 1 ? '1 character' : `${count} characters`,
    { exact: true },
  );
  let tries = 0;
  await expect(async () => {
    await fillField(sourceInput(page), text, { refocus: tries++ > 0 });
    await expect(label).toBeVisible({ timeout: 5_000 });
  }).toPass({ timeout: 40_000 });
}

/**
 * The accessibility tree of the page as Playwright's ARIA snapshot (YAML):
 * what a screen reader can read.
 */
function accessibilityTree(page) {
  return page.locator('body').ariaSnapshot();
}

/**
 * Scrolls the page (mouse wheel at the middle of the viewport) until
 * [locator] is in the semantics tree; Flutter only builds semantics for
 * the visible part of a lazy list.
 */
async function scrollTo(page, locator, { maxSteps = 15 } = {}) {
  const { width, height } = page.viewportSize();
  await page.mouse.move(width / 2, height / 2);
  for (let i = 0; i < maxSteps; i++) {
    if ((await locator.count()) > 0 && (await locator.first().isVisible())) {
      return;
    }
    await page.mouse.wheel(0, 400);
    // Let the scroll settle so the semantics tree is rebuilt.
    await page.waitForTimeout(150);
  }
  await expect(locator.first()).toBeVisible();
}

/**
 * The mean luminance (0 = black, 255 = white) of the viewport, read from a
 * screenshot: Flutter draws to a canvas, so the theme can't be read from
 * CSS.
 */
async function meanLuminance(page) {
  const png = await page.screenshot();
  return page.evaluate(async (base64) => {
    const bytes = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
    const bitmap = await createImageBitmap(
      new Blob([bytes], { type: 'image/png' }),
    );
    const canvas = new OffscreenCanvas(bitmap.width, bitmap.height);
    const context = canvas.getContext('2d');
    context.drawImage(bitmap, 0, 0);
    const { data } = context.getImageData(0, 0, bitmap.width, bitmap.height);
    let sum = 0;
    for (let i = 0; i < data.length; i += 4) {
      sum += 0.2126 * data[i] + 0.7152 * data[i + 1] + 0.0722 * data[i + 2];
    }
    return sum / (data.length / 4);
  }, png.toString('base64'));
}

/** The on-device engine's worker (web/bergamot/worker.js). */
const ENGINE_WORKER = 'bergamot/worker.js';

/**
 * Makes the page start as in a browser that cannot run the on-device
 * engine (or a build without it): its worker does not load. The request
 * fails (where the browser lets Playwright see a worker's requests), and
 * constructing the worker throws (everywhere).
 */
async function blockOnDeviceEngine(page) {
  await page.route(`**/${ENGINE_WORKER}`, (route) =>
    route.fulfill({ status: 404, body: '' }),
  );
  await page.addInitScript((script) => {
    const Original = window.Worker;
    if (typeof Original !== 'function') return;
    function Worker(url, options) {
      if (String(url).endsWith(script)) {
        throw new DOMException(`${script} is blocked by the test`, 'SecurityError');
      }
      return new Original(url, options);
    }
    Worker.prototype = Original.prototype;
    window.Worker = Worker;
  }, ENGINE_WORKER);
}

/**
 * What this browser lacks of what the on-device engine needs, asked from
 * the engine's own worker (its `probe`, which the app asks too:
 * packages/bergamot_translator/lib/src/engine/web/web_support.dart, whose
 * rules this repeats). Empty when the app translates on the device here.
 * Needs a page of the app (the worker is next to it).
 */
async function onDeviceEngineMissing(page) {
  const probe = await page.evaluate(
    (script) =>
      new Promise((resolve) => {
        let worker;
        try {
          worker = new Worker(new URL(script, document.baseURI));
        } catch (error) {
          resolve({ error: String(error) });
          return;
        }
        const done = (answer) => {
          clearTimeout(timer);
          worker.terminate();
          resolve(answer);
        };
        const timer = setTimeout(() => done({ error: 'no answer' }), 10_000);
        worker.onmessage = (event) =>
          done(event.data && event.data.ok ? event.data.result : { error: 'failed' });
        worker.onerror = (event) => done({ error: event.message || 'error' });
        worker.postMessage({ id: 1, op: 'probe' });
      }),
    ENGINE_WORKER,
  );
  if (probe.error) return [`engine files (${probe.error})`];
  const missing = [];
  if (!probe.engine) missing.push('engine files');
  if (!probe.secure || !probe.digest) missing.push('secure context');
  if (probe.secure && (!probe.opfs || !probe.syncAccess)) {
    missing.push('private storage (OPFS with sync access)');
  }
  if (!probe.simd) missing.push('WebAssembly SIMD');
  if (!probe.decompression) missing.push('DecompressionStream');
  if (!probe.segmenter) missing.push('Intl.Segmenter');
  return missing;
}

/**
 * Skips the running test when this browser cannot run the on-device
 * engine ([onDeviceEngineMissing]); the app then works online only, which
 * the specs without the engine cover. Call it on a page of the app.
 */
async function skipWithoutOnDeviceEngine(page) {
  const missing = await onDeviceEngineMissing(page);
  test.skip(
    missing.length > 0,
    `This browser cannot run the on-device engine: no ${missing.join(', ')}`,
  );
}

/** Blocks every request to the mock server, as if it were down. */
async function takeMockDown(page) {
  await page.route(`http://127.0.0.1:${MOCK_PORT}/**`, (route) =>
    route.abort('connectionrefused'),
  );
}

/**
 * Clicks the app bar button [name], then moves the pointer off it.
 *
 * While the pointer rests on a button its tooltip is merged into its name
 * ("Back Back"), so the button is matched with or without it; moving the
 * pointer away keeps it from resting on the button that the next screen
 * shows at the same place (both pages' Back arrows).
 */
async function clickAppBarButton(page, name) {
  const label = escapeRegExp(name);
  await page
    .getByRole('button', { name: new RegExp(`^${label}( ${label})?$`) })
    .first()
    .click();
  await page.mouse.move(0, 0);
}

/**
 * Opens History or Settings with its button in the current tab's app bar
 * (they are pages above the tabs, not tabs) and waits for its heading.
 */
async function openPage(page, name) {
  await clickAppBarButton(page, name);
  await expect(
    page.getByRole('heading', { name, exact: true }).first(),
  ).toBeVisible();
}

/** Opens History from the app bar (see [openPage]). */
function openHistory(page) {
  return openPage(page, 'History');
}

/** Opens Settings from the app bar (see [openPage]). */
function openSettings(page) {
  return openPage(page, 'Settings');
}

/**
 * Opens the settings category [name] ("Privacy & data", "Appearance", …)
 * from the list of categories on the settings page and waits for its
 * title. In a phone-sized window the category is a page of its own
 * (`/settings/<category>`), above the list: [goBack] returns to the list.
 */
async function openSettingsCategory(page, name) {
  const pattern = new RegExp(`^${escapeRegExp(name)}(\\s|$)`);
  await page.getByRole('button', { name: pattern }).first().click();
  await expect(page.getByRole('heading', { name: pattern }).first())
    .toBeVisible();
}

/**
 * Leaves History or Settings with the app bar's back arrow: back to the
 * tab it was opened from, or the translate tab when it was opened on its
 * own (e.g. `openApp(page, '/settings')`). A settings category goes back
 * to the list of categories first, also when it was opened on its own
 * (`/settings/privacy` stacks on `/settings`).
 */
async function goBack(page) {
  await clickAppBarButton(page, 'Back');
}

module.exports = {
  MOCK_PORT,
  blockOnDeviceEngine,
  clearClipboard,
  collectPageErrors,
  accessibilityTree,
  copiedTranslation,
  escapeRegExp,
  fillField,
  goBack,
  loadSettings,
  meanLuminance,
  openApp,
  openHistory,
  openSettings,
  openSettingsCategory,
  onDeviceEngineMissing,
  readClipboard,
  recordAiRequests,
  scrollTo,
  seedSettings,
  skipWithoutOnDeviceEngine,
  sourceInput,
  takeMockDown,
  test,
  typeSource,
  waitForSemantics,
};
