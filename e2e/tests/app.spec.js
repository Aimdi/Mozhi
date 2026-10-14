// Smoke tests: the app starts, the More tools menu opens and the main
// (including deferred, separately downloaded) routes render.
const { test, expect } = require('@playwright/test');
const { collectPageErrors, openApp, seedSettings } = require('./helpers');

test.beforeEach(async ({ page }) => {
  await seedSettings(page, 'settings-ai');
});

test('app loads on the translate tab', async ({ page }) => {
  const errors = collectPageErrors(page);
  await openApp(page, '/translate');

  await expect(page.getByRole('tab', { name: 'Translate' })).toHaveAttribute(
    'aria-selected',
    'true',
  );
  for (const tab of ['Proofread', 'History', 'Settings']) {
    await expect(page.getByRole('tab', { name: tab })).toBeVisible();
  }
  await expect(
    page.getByRole('textbox', { name: 'Text to translate' }),
  ).toBeVisible();
  // The seeded AI provider is the selected engine.
  await expect(
    page.getByRole('button', { name: /Local AI \(mock\)/ }).first(),
  ).toBeVisible();
  expect(errors).toEqual([]);
});

test('More tools menu opens and closes', async ({ page }) => {
  await openApp(page, '/translate');
  await page.getByRole('button', { name: 'More tools' }).click();

  const menu = page.getByRole('menu');
  await expect(menu).toBeVisible();
  for (const item of ['Documents', 'Web page', 'Conversation', 'Dictionary']) {
    await expect(menu.getByRole('menuitem', { name: item })).toBeVisible();
  }

  await page.keyboard.press('Escape');
  await expect(menu).toBeHidden();
});

test.describe('routes render', () => {
  test('settings', async ({ page }) => {
    await openApp(page, '/settings');
    await expect(page.getByRole('heading', { name: 'Settings' })).toBeVisible();
    await expect(
      page.getByRole('button', { name: /^AI providers/ }),
    ).toBeVisible();
    await expect(
      page.getByRole('switch', { name: /^Instant translate with AI/ }),
    ).toBeVisible();
  });

  test('quality modes', async ({ page }) => {
    await openApp(page, '/settings/quality');
    await expect(
      page.getByRole('heading', { name: 'Quality modes' }),
    ).toBeVisible();
    await expect(page.getByRole('banner', { name: 'Fast' })).toBeVisible();
    await expect(page.getByRole('banner', { name: 'Best' })).toBeVisible();
  });

  test('usage (deferred)', async ({ page }) => {
    await openApp(page, '/settings/usage');
    await expect(page.getByRole('heading', { name: 'Usage' })).toBeVisible();
    await expect(
      page.getByRole('button', { name: /^Local AI \(mock\)/ }),
    ).toBeVisible();
  });

  test('dictionary (deferred) prefills without looking up', async ({
    page,
  }) => {
    const aiCalls = [];
    page.on('request', (r) => {
      if (r.url().includes('/v1/chat/completions')) aiCalls.push(r.url());
    });
    await openApp(page, '/dictionary?word=hello&from=en&to=fr');
    await expect(page.getByRole('heading', { name: 'Dictionary' })).toBeVisible();
    await expect(
      page.getByRole('button', { name: 'Language of the word: English' }),
    ).toBeVisible();
    await expect(
      page.getByRole('button', { name: 'Translations in: French' }),
    ).toBeVisible();
    await expect(page.getByRole('button', { name: 'Look up' })).toBeVisible();
    expect(aiCalls).toEqual([]);
  });

  test('documents (deferred)', async ({ page }) => {
    await openApp(page, '/documents');
    await expect(
      page.getByRole('heading', { name: 'Translate documents' }),
    ).toBeVisible();
    await expect(
      page.getByRole('button', { name: 'Choose file' }),
    ).toBeVisible();
    await expect(
      page.getByRole('button', { name: 'Translate into French' }),
    ).toBeVisible();
  });
});
