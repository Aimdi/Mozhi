// Settings round trips: turning history off and switching to the dark
// theme and its Lights out look (which must survive a reload).
const { expect } = require('@playwright/test');
const {
  copiedTranslation,
  meanLuminance,
  openApp,
  scrollTo,
  seedSettings,
  test,
  typeSource,
} = require('./helpers');

test.beforeEach(async ({ page }) => {
  await seedSettings(page, 'settings-ai');
});

test('with Save history off, translations are not saved', async ({
  page,
}) => {
  await openApp(page, '/settings');
  // Save history is in the Data section, further down on a phone.
  const saveHistory = page.getByRole('switch', { name: /^Save history/ });
  await scrollTo(page, saveHistory);
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
  await scrollTo(page, saveHistory);
  await expect(saveHistory).not.toBeChecked();

  // The banner turns it back on.
  await page.getByRole('tab', { name: 'History' }).click();
  await banner.getByRole('button', { name: 'Turn on' }).click();
  await expect(banner).toBeHidden();
  await page.getByRole('tab', { name: 'Settings' }).click();
  await scrollTo(page, saveHistory);
  await expect(saveHistory).toBeChecked();
});

test('the dark theme and its look persist after a reload', async ({
  page,
}) => {
  await openApp(page, '/settings');
  const theme = page.getByRole('group', { name: 'Theme' });
  await scrollTo(page, theme);
  // The seeded settings use the light theme; the dark look (Dim or
  // Lights out) only applies to the dark one.
  const darkLook = page.getByRole('group', { name: 'Dark theme' });
  const lightsOut = darkLook.getByRole('radio', { name: 'Lights out' });
  const dim = darkLook.getByRole('radio', { name: 'Dim' });
  await expect(lightsOut).toBeDisabled();
  const light = await meanLuminance(page);
  expect(light).toBeGreaterThan(150);

  await theme.getByRole('button', { name: 'Dark' }).click();
  await expect(lightsOut).toBeEnabled();
  await expect(dim).toBeChecked();
  await expect.poll(() => meanLuminance(page)).toBeLessThan(100);
  const dimLuminance = await meanLuminance(page);

  await scrollTo(page, lightsOut);
  await lightsOut.click();
  await expect(lightsOut).toBeChecked();
  // True black is darker still than Dim's blue-grey.
  await expect.poll(() => meanLuminance(page)).toBeLessThan(dimLuminance);

  await page.reload();
  await openApp(page, '/settings');
  await scrollTo(page, page.getByRole('group', { name: 'Dark theme' }));
  await expect(
    page
      .getByRole('group', { name: 'Dark theme' })
      .getByRole('radio', { name: 'Lights out' }),
  ).toBeChecked();
  await expect.poll(() => meanLuminance(page)).toBeLessThan(100);

  // Other screens use it too.
  await page.getByRole('tab', { name: 'Translate' }).click();
  await expect(
    page.getByRole('textbox', { name: 'Text to translate' }),
  ).toBeVisible();
  await expect.poll(() => meanLuminance(page)).toBeLessThan(100);
});
