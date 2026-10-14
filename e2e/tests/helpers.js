// Shared helpers for the Mozhi web E2E specs.
const fs = require('node:fs');
const path = require('node:path');
const { expect } = require('@playwright/test');

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
 */
async function copiedTranslation(page) {
  await page.evaluate(() => navigator.clipboard.writeText(''));
  // While the pointer rests on the button its tooltip ("Copy") is merged
  // into the label; move the pointer away afterwards so the next call
  // finds the plain label again.
  await page.getByRole('button', { name: /^Copy( Copy)?$/ }).click();
  await page.mouse.move(0, 0);
  return page.evaluate(() => navigator.clipboard.readText());
}

/** Types [text] into the translate screen's input. */
async function typeSource(page, text) {
  const input = sourceInput(page);
  await input.click();
  await input.fill(text);
}

module.exports = {
  MOCK_PORT,
  collectPageErrors,
  copiedTranslation,
  enableSemantics,
  loadSettings,
  openApp,
  recordAiRequests,
  seedSettings,
  sourceInput,
  typeSource,
};
