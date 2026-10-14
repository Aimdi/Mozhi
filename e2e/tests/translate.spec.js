// Translating with the (mock) AI provider: instant translation, a
// refinement chip and the meaning check.
const { expect } = require('@playwright/test');
const {
  copiedTranslation,
  openApp,
  recordAiRequests,
  seedSettings,
  test,
  typeSource,
} = require('./helpers');

const TEXT = 'Good morning, how are you today?';
// The mock answers "[AI→<target name>] <text>" (after a <think> block the
// app strips).
const TRANSLATION = `[AI→French (Français)] ${TEXT}`;

test.beforeEach(async ({ page }) => {
  await seedSettings(page, 'settings-ai');
  await openApp(page, '/translate');
});

/** Types [TEXT] and waits until the AI translation is shown. */
async function translate(page) {
  await typeSource(page, TEXT);
  await expect(
    page.getByRole('button', { name: 'Copy', exact: true }),
  ).toBeVisible();
  await expect.poll(() => copiedTranslation(page)).toBe(TRANSLATION);
}

test('typing translates with the AI provider', async ({ page }) => {
  const requests = recordAiRequests(page);
  await translate(page);

  // The result card names the engine that produced it.
  await expect(
    page.getByRole('group', { name: /^Local AI \(mock\) · / }),
  ).toBeVisible();
  // The source language was detected.
  await expect(
    page.getByRole('button', { name: 'Source language: Detected: English' }),
  ).toBeVisible();
  expect(requests.length).toBeGreaterThanOrEqual(1);
  expect(requests[0].model).toBe('mock-translator-8b');
  expect(requests[0].stream).toBe(true);
});

test('a refine chip refines the translation', async ({ page }) => {
  await translate(page);

  const refine = page.getByRole('group', { name: 'Refine' });
  await refine.getByRole('checkbox', { name: 'More formal' }).click();

  // The chip turns into an undo chip once the refinement is applied.
  await expect(
    refine.getByRole('checkbox', { name: /^Undo “More formal”/ }),
  ).toBeChecked();
  await expect
    .poll(() => copiedTranslation(page))
    .toBe(`[refined] ${TRANSLATION}`);
});

test('meaning check shows a verdict and its differences', async ({ page }) => {
  await translate(page);

  await page.getByRole('button', { name: 'Check meaning' }).click();

  await expect(
    page.getByRole('heading', { name: 'Meaning check' }),
  ).toBeVisible();
  await expect(page.getByText('Minor differences')).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Differences' })).toBeVisible();
  await expect(
    page.getByRole('button', {
      name: /^Omission The time reference is weaker in the translation\./,
    }),
  ).toBeVisible();
});
