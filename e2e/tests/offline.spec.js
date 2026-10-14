// No network: with the AI provider and the Mozhi instance unreachable the
// app shows a friendly error instead of crashing, and recovers once they
// are back.
const { test, expect } = require('@playwright/test');
const {
  collectPageErrors,
  copiedTranslation,
  openApp,
  seedSettings,
  takeMockDown,
  typeSource,
} = require('./helpers');

test('an unreachable AI provider shows a friendly error', async ({
  page,
}) => {
  await seedSettings(page, 'settings-ai');
  const errors = collectPageErrors(page);
  await takeMockDown(page);
  await openApp(page, '/translate');

  await typeSource(page, 'Good evening');
  await expect(
    page.getByText(
      "Couldn't reach the AI provider. Check your connection and the server URL.",
    ),
  ).toBeVisible();
  await expect(page.getByRole('button', { name: 'Copy', exact: true }))
    .toBeHidden();

  // The app still works: other tabs open and the input is kept.
  await page.getByRole('tab', { name: 'History' }).click();
  await expect(page.getByRole('heading', { name: 'History' })).toBeVisible();
  await page.getByRole('tab', { name: 'Translate' }).click();
  await expect(
    page.getByRole('textbox', { name: 'Text to translate' }),
  ).toBeVisible();

  // Back online: Retry translates.
  await page.unrouteAll();
  await page.getByRole('button', { name: 'Retry' }).click();
  await expect
    .poll(() => copiedTranslation(page))
    .toBe('[AI→French (Français)] Good evening');
  expect(errors).toEqual([]);
});

test('an unreachable Mozhi instance shows a friendly error', async ({
  page,
}) => {
  await seedSettings(page, 'settings-ai', { engineId: 'mozhi:google' });
  const errors = collectPageErrors(page);
  await takeMockDown(page);
  await openApp(page, '/translate');

  await typeSource(page, 'Good evening');
  await expect(
    page.getByText(
      "Couldn't reach the Mozhi instance. Check your connection or try another instance.",
    ),
  ).toBeVisible();
  expect(errors).toEqual([]);
});
