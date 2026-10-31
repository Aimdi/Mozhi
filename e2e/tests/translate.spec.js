// Translating with the (mock) AI provider: instant translation, a
// refinement chip (always under an AI translation) and the meaning check
// (in the "Tools" area under the translation, closed by default).
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

/** The "Tools" disclosure under the translation. */
function toolsButton(page) {
  return page.getByRole('button', { name: 'Tools', exact: true });
}

/** Opens the "Tools" area under the translation. */
async function openTools(page) {
  const tools = toolsButton(page);
  await tools.click();
  await expect(tools).toHaveAttribute('aria-expanded', 'true');
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

  // One task on screen: the tools wait behind "Tools".
  await expect(toolsButton(page)).toHaveAttribute('aria-expanded', 'false');
  await expect(page.getByRole('heading', { name: 'Learn', exact: true }))
    .toHaveCount(0);
  await expect(page.getByRole('checkbox', { name: 'Check meaning' }))
    .toHaveCount(0);
  // The refinement chips are always under an AI translation.
  const refine = page.getByRole('group', { name: 'Refine', exact: true });
  for (const chip of ['More formal', 'More casual', 'Shorter', 'Simpler']) {
    await expect(refine.getByRole('checkbox', { name: chip })).toBeVisible();
  }
});

test('a refine chip refines the translation', async ({ page }) => {
  await translate(page);
  await openTools(page);

  const refine = page.getByRole('group', { name: 'Refine', exact: true });
  await refine.getByRole('checkbox', { name: 'More formal' }).click();
  // The chip turns into an undo chip once the refinement is applied; wait
  // for it first: the result grows meanwhile, and a click aimed at a spot
  // that moves can land on one of its buttons (Add to phrasebook).
  // Matched by name, not role: while its tooltip shows (focus or hover)
  // Flutter web drops the chip's checkbox role, and when that happens is
  // timing dependent. Its checked state is covered by the widget tests.
  await expect(refine.getByLabel(/^Undo “More formal”/)).toBeVisible();
  // Moving the focus off the chip (a click on the Tools area's heading)
  // brings its role back.
  await page.getByRole('heading', { name: 'Learn', exact: true }).click();

  // Wait for the refinement first: copying also moves the focus off the
  // chip, which Flutter web may have refocused when it was rebuilt.
  await expect
    .poll(() => copiedTranslation(page))
    .toBe(`[refined] ${TRANSLATION}`);
  // The result's header names the refinement, with an × that undoes it.
  await expect(
    page
      .getByRole('group', { name: /^French\b[\s\S]*Local AI \(mock\) · / })
      .getByRole('button', { name: 'Undo “More formal”', exact: true }),
  ).toBeVisible();
});

test('meaning check shows a verdict and its differences', async ({ page }) => {
  await translate(page);
  await openTools(page);

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

test('the Tools area stays open for the next translation', async ({
  page,
}) => {
  await translate(page);
  await openTools(page);
  await expect(page.getByRole('heading', { name: 'Learn', exact: true }))
    .toBeVisible();

  await typeSource(page, 'See you tomorrow');
  await expect
    .poll(() => copiedTranslation(page))
    .toBe('[AI→French (Français)] See you tomorrow');
  await expect(toolsButton(page)).toHaveAttribute('aria-expanded', 'true');
  await expect(page.getByRole('heading', { name: 'Learn', exact: true }))
    .toBeVisible();
});
