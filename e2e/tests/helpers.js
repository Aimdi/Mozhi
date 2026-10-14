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
 * The Playwright `test` with an automatic check that fails any test whose
 * page logged a Content Security Policy violation (web/index.html sets a
 * strict CSP; a blocked script, font or request shows up as a console
 * error mentioning it). Specs import `test` from here.
 */
const test = base.extend({
  cspViolations: [
    async ({ page }, use) => {
      const violations = [];
      page.on('console', (message) => {
        if (
          message.type() === 'error' &&
          message.text().includes('Content Security Policy')
        ) {
          violations.push(message.text());
        }
      });
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
 * Turns on Flutter's semantics tree so widgets are exposed as ARIA roles
 * and labels (Flutter web only builds it after the placeholder is
 * activated).
 */
async function enableSemantics(page) {
  const placeholder = page.locator('flt-semantics-placeholder');
  await expect(placeholder).toBeAttached({ timeout: 60_000 });
  await placeholder.dispatchEvent('click');
  await expect(page.locator('flt-semantics').first()).toBeAttached();
}

/**
 * Opens the app at [location] (a router location such as `/translate` or
 * `/settings/usage?x=1`; the app uses the hash URL strategy) and enables
 * semantics.
 */
async function openApp(page, location = '/translate') {
  await page.goto(`/#${location}`);
  await enableSemantics(page);
}

/** The translate screen's text input. */
function sourceInput(page) {
  return page.getByRole('textbox', { name: 'Text to translate' });
}

/**
 * The text of the current translation.
 *
 * The output is a read-only field whose text is not part of the semantics
 * tree (CanvasKit draws it), so this presses the result card's Copy button
 * and reads the clipboard (the context grants clipboard permissions).
 * [scope] narrows the search for the button (e.g. the proofread result).
 */
async function copiedTranslation(page, scope = page) {
  await page.evaluate(() => navigator.clipboard.writeText(''));
  // While the pointer rests on the button its tooltip ("Copy") is merged
  // into the label; move the pointer away afterwards so the next call
  // finds the plain label again.
  await scope.getByRole('button', { name: /^Copy( Copy)?$/ }).click();
  await page.mouse.move(0, 0);
  return page.evaluate(() => navigator.clipboard.readText());
}

/**
 * Focuses the text field [locator] and replaces its text with [text].
 *
 * Flutter creates the DOM input that receives the text only once the
 * field has focus, so a fill right after the click can be lost: this
 * retries until the field holds [text].
 */
async function fillField(locator, text) {
  await expect(async () => {
    await locator.click();
    await locator.fill(text);
    await expect(locator).toHaveValue(text, { timeout: 2_000 });
  }).toPass({ timeout: 20_000 });
}

/** Types [text] into the translate screen's input. */
async function typeSource(page, text) {
  await fillField(sourceInput(page), text);
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

/** Blocks every request to the mock server, as if it were down. */
async function takeMockDown(page) {
  await page.route(`http://127.0.0.1:${MOCK_PORT}/**`, (route) =>
    route.abort('connectionrefused'),
  );
}

module.exports = {
  MOCK_PORT,
  collectPageErrors,
  copiedTranslation,
  enableSemantics,
  fillField,
  loadSettings,
  meanLuminance,
  openApp,
  recordAiRequests,
  scrollTo,
  seedSettings,
  sourceInput,
  takeMockDown,
  test,
  typeSource,
};
