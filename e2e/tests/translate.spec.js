// Translating with the (mock) AI provider: instant translation, a
// refinement chip and the meaning check.
const { expect } = require('@playwright/test');
const {
  copiedTranslation,
  openApp,
  recordAiRequests,
  scrollTo,
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

  // The result's header names the target language, then the engine that
  // produced it (X-style "French · Local AI (mock) · 0.4 s").
  await expect(
    page.getByRole('group', { name: /^French\b[\s\S]*Local AI \(mock\) · / }),
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
  // While the focused chip shows its tooltip, Flutter web drops the
  // chip's checkbox role (also before the redesign); moving the focus off
  // it (a click on the section heading) brings the role back.
  await page.getByRole('heading', { name: 'Refine & learn' }).click();

  // Wait for the refinement first: copying also moves the focus off the
  // chip, which Flutter web may have refocused when it was rebuilt.
  await expect
    .poll(() => copiedTranslation(page))
    .toBe(`[refined] ${TRANSLATION}`);
  // The chip turned into an undo chip once the refinement was applied.
  // The longer refined text can push the chips below the fold, where
  // Flutter builds no semantics: scroll them back into view.
  const undo = refine.getByRole('checkbox', { name: /^Undo “More formal”/ });
  await scrollTo(page, undo);
  await expect(undo).toBeChecked();
});

test('meaning check shows a verdict and its differences', async ({ page }) => {
  await translate(page);

  await page.getByRole('checkbox', { name: 'Check meaning' }).click();

  await expect(
    page.getByRole('heading', { name: 'Meaning check' }),
  ).toBeVisible();
  await expect(
    page.getByText('Minor differences', { exact: true }),
  ).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Differences' })).toBeVisible();
  await expect(
    page.getByRole('button', {
      name: /^Omission The time reference is weaker in the translation\./,
    }),
  ).toBeVisible();
});
