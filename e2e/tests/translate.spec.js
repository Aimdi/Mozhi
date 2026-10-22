// Translating with the (mock) AI provider: instant translation, a
// refinement chip and the meaning check (both in the "More" area under the
// translation, closed by default).
const { expect } = require('@playwright/test');
const {
  accessibilityTree,
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

/** Opens the "More" area under the translation. */
async function openMore(page) {
  const more = page.getByRole('button', { name: 'More', exact: true });
  await more.click();
  await expect(more).toHaveAttribute('aria-expanded', 'true');
}

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

  // A screen reader can read the translation itself (on the web the
  // selectable text alone would be an empty, disabled field).
  await expect.poll(() => accessibilityTree(page)).toContain(TRANSLATION);

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

  // One task on screen: the tools wait behind "More".
  await expect(
    page.getByRole('button', { name: 'More', exact: true }),
  ).toHaveAttribute('aria-expanded', 'false');
  await expect(page.getByRole('heading', { name: 'Refine & learn' }))
    .toHaveCount(0);
  await expect(page.getByRole('checkbox', { name: 'Check meaning' }))
    .toHaveCount(0);
});

test('a refine chip refines the translation', async ({ page }) => {
  await translate(page);
  await openMore(page);

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
  // Matched by name, not role: while its tooltip shows (focus or hover)
  // Flutter web drops the chip's checkbox role, and when that happens is
  // timing dependent. Its checked state is covered by the widget tests.
  await expect(refine.getByLabel(/^Undo “More formal”/)).toBeVisible();
});

test('meaning check shows a verdict and its differences', async ({ page }) => {
  await translate(page);
  await openMore(page);

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

test('the More area stays open for the next translation', async ({
  page,
}) => {
  await translate(page);
  await openMore(page);
  await expect(page.getByRole('heading', { name: 'Refine & learn' }))
    .toBeVisible();

  await typeSource(page, 'See you tomorrow');
  await expect
    .poll(() => copiedTranslation(page))
    .toBe('[AI→French (Français)] See you tomorrow');
  await expect(
    page.getByRole('button', { name: 'More', exact: true }),
  ).toHaveAttribute('aria-expanded', 'true');
  await expect(page.getByRole('heading', { name: 'Refine & learn' }))
    .toBeVisible();
});
