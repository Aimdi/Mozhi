// Settings round trips: turning history off and switching to the dark
// theme (which must survive a reload).
const { test, expect } = require('@playwright/test');
const {
  copiedTranslation,
  meanLuminance,
  openApp,
  scrollTo,
  seedSettings,
  typeSource,
} = require('./helpers');

test.beforeEach(async ({ page }) => {
  await seedSettings(page, 'settings-ai');
});

test('with Save history off, translations are not saved', async ({
  page,
}) => {
  await openApp(page, '/settings');
  const saveHistory = page.getByRole('switch', { name: /^Save history/ });
  await expect(saveHistory).toBeChecked();
  await saveHistory.click();
  await expect(saveHistory).not.toBeChecked();

  await page.getByRole('tab', { name: 'Translate' }).click();
  await typeSource(page, 'Good evening');
  await expect
    .poll(() => copiedTranslation(page))
    .toBe('[AI→French (Français)] Good evening');

  await page.getByRole('tab', { name: 'History' }).click();
  const banner = page.getByRole('group', {
    name: "History is off. New translations aren't saved.",
  });
  await expect(banner).toBeVisible();
  await expect(page.getByRole('heading', { name: /^No history yet/ }))
    .toBeVisible();
  await expect(page.getByRole('group', { name: /Good evening/ })).toBeHidden();

  // The setting is stored: still off after a reload.
  await page.reload();
  await openApp(page, '/settings');
  await expect(
    page.getByRole('switch', { name: /^Save history/ }),
  ).not.toBeChecked();

  // The banner turns it back on.
  await page.getByRole('tab', { name: 'History' }).click();
  await banner.getByRole('button', { name: 'Turn on' }).click();
  await expect(banner).toBeHidden();
  await page.getByRole('tab', { name: 'Settings' }).click();
  await expect(page.getByRole('switch', { name: /^Save history/ }))
    .toBeChecked();
});

test('the dark theme persists after a reload', async ({ page }) => {
  await openApp(page, '/settings');
  const theme = page.getByRole('group', { name: 'Theme' });
  await scrollTo(page, theme);
  // The seeded settings use the light theme; "Pure black" only applies
  // to the dark one.
  const pureBlack = page.getByRole('switch', { name: /^Pure black/ });
  await expect(pureBlack).toBeDisabled();
  const light = await meanLuminance(page);
  expect(light).toBeGreaterThan(150);

  await theme.getByRole('button', { name: 'Dark' }).click();
  await expect(pureBlack).toBeEnabled();
  await expect.poll(() => meanLuminance(page)).toBeLessThan(100);

  await page.reload();
  await openApp(page, '/settings');
  await scrollTo(page, page.getByRole('group', { name: 'Theme' }));
  await expect(page.getByRole('switch', { name: /^Pure black/ }))
    .toBeEnabled();
  await expect.poll(() => meanLuminance(page)).toBeLessThan(100);

  // Other screens use it too.
  await page.getByRole('tab', { name: 'Translate' }).click();
  await expect(
    page.getByRole('textbox', { name: 'Text to translate' }),
  ).toBeVisible();
  await expect.poll(() => meanLuminance(page)).toBeLessThan(100);
});
