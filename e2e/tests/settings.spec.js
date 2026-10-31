// Settings round trips: turning history off (Privacy & data) and switching
// to the Classic style's dark theme and its Lights out look (Appearance,
// found with the settings search), which must survive a reload.
const { expect } = require('@playwright/test');
const {
  copiedTranslation,
  fillField,
  goBack,
  meanLuminance,
  openApp,
  openHistory,
  openSettings,
  openSettingsCategory,
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
  // Save history is in Privacy & data, in its History group.
  await openSettingsCategory(page, 'Privacy & data');
  const saveHistory = page.getByRole('switch', { name: /^Save history/ });
  await scrollTo(page, saveHistory);
  await expect(saveHistory).toBeChecked();
  await saveHistory.click();
  await expect(saveHistory).not.toBeChecked();

  // Back to the list of categories, then (Settings was opened on its own)
  // to the translate tab.
  await goBack(page);
  await expect(page.getByRole('heading', { name: 'Settings' })).toBeVisible();
  await goBack(page);
  await typeSource(page, 'Good evening');
  await expect
    .poll(() => copiedTranslation(page))
    .toBe('[AI→French (Français)] Good evening');

  await openHistory(page);
  // "History is paused" + the reason (the name matches a substring).
  const banner = page.getByRole('group', {
    name: "History is off. New translations aren't saved.",
  });
  await expect(banner).toHaveAccessibleName(/^History is paused/);
  await expect(banner).toBeVisible();
  await expect(page.getByRole('heading', { name: /^No history yet/ }))
    .toBeVisible();
  await expect(page.getByRole('group', { name: /Good evening/ })).toBeHidden();

  // The setting is stored: still off after a reload. A link can open the
  // row directly.
  await page.reload();
  await openApp(page, '/settings/privacy?row=save_history');
  await expect(
    page.getByRole('heading', { name: 'Privacy & data' }),
  ).toBeVisible();
  await scrollTo(page, saveHistory);
  await expect(saveHistory).not.toBeChecked();

  // The banner turns it back on. Opened on its own, the category goes
  // back to the list of categories first.
  await goBack(page);
  await expect(page.getByRole('heading', { name: 'Settings' })).toBeVisible();
  await goBack(page);
  await openHistory(page);
  await banner.getByRole('button', { name: 'Turn on' }).click();
  await expect(banner).toBeHidden();
  await goBack(page);
  await openSettings(page);
  await openSettingsCategory(page, 'Privacy & data');
  await scrollTo(page, saveHistory);
  await expect(saveHistory).toBeChecked();
});

test('the dark theme and its look persist after a reload', async ({
  page,
}) => {
  // Dim and Lights out belong to the Classic style (Terminal, the default,
  // has its own near-black): switch to it in Appearance first.
  await openApp(page, '/settings/appearance');
  const classic = page.getByRole('radio', { name: /^Classic\b/ });
  await scrollTo(page, classic);
  await classic.click();
  await expect(classic).toBeChecked();
  await goBack(page);
  await expect(page.getByRole('heading', { name: 'Settings' })).toBeVisible();
  // The search finds the row by its name and opens its category.
  await fillField(
    page.getByRole('searchbox', { name: 'Search settings' }),
    'dark theme',
  );
  const result = page.getByRole('button', { name: /^Dark theme\s+Appearance/ });
  await expect(result).toBeVisible();
  // Screen readers hear how many rows match (a polite live region).
  await expect(page.locator('flt-announcement-polite')).toHaveText(
    /^\d+ settings? found$/,
  );
  // Only the matching rows are listed, not the categories.
  await expect(
    page.getByRole('button', { name: /^Privacy & data / }),
  ).toHaveCount(0);
  await result.click();
  await expect(
    page.getByRole('heading', { name: 'Appearance', exact: true }),
  ).toBeVisible();
  const theme = page.getByRole('group', { name: 'Theme', exact: true });
  await scrollTo(page, theme);
  // The seeded settings use the light theme; the dark look (Dim or
  // Lights out) only applies to the dark one.
  const darkLook = page.getByRole('group', { name: 'Dark theme' });
  const lightsOut = darkLook.getByRole('radio', { name: 'Lights out' });
  const dim = darkLook.getByRole('radio', { name: 'Dim' });
  await scrollTo(page, lightsOut);
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
  await openApp(page, '/settings/appearance');
  const lightsOutAfterReload = page
    .getByRole('group', { name: 'Dark theme' })
    .getByRole('radio', { name: 'Lights out' });
  await scrollTo(page, lightsOutAfterReload);
  await expect(lightsOutAfterReload).toBeChecked();
  await expect.poll(() => meanLuminance(page)).toBeLessThan(100);

  // Other screens use it too: the list of categories, then the translate
  // tab.
  await goBack(page);
  await expect(page.getByRole('heading', { name: 'Settings' })).toBeVisible();
  await expect.poll(() => meanLuminance(page)).toBeLessThan(100);
  await goBack(page);
  await expect(
    page.getByRole('textbox', { name: 'Text to translate' }),
  ).toBeVisible();
  await expect.poll(() => meanLuminance(page)).toBeLessThan(100);
});
