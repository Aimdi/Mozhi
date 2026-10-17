// Smoke tests: the app starts, the More tools menu opens and the main
// (including deferred, separately downloaded) routes render.
const { expect } = require('@playwright/test');
const {
  collectPageErrors,
  enableSemantics,
  openApp,
  scrollTo,
  seedSettings,
  test,
} = require('./helpers');

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

test('first run: at most three steps after the welcome', async ({ page }) => {
  const errors = collectPageErrors(page);
  await openApp(page, '/translate');
  // Turn the seeded settings into a first run (the seed only applies once
  // per session, so the reload keeps this).
  await page.evaluate(() => {
    const settings = JSON.parse(JSON.parse(localStorage.getItem('settings.v1')));
    settings.onboardingComplete = false;
    localStorage.setItem('settings.v1', JSON.stringify(JSON.stringify(settings)));
  });
  await page.reload();
  await enableSemantics(page);

  await expect(
    page.getByRole('heading', { name: 'Welcome to Mozhi' }),
  ).toBeVisible();
  const next = page.getByRole('button', { name: 'Next' });

  await next.click();
  await expect(
    page.getByRole('heading', { name: 'How private should translations be?' }),
  ).toBeVisible();

  await next.click();
  await expect(
    page.getByRole('heading', { name: 'Pick your languages' }),
  ).toBeVisible();
  await expect(
    page.getByRole('button', { name: /^Translate into\s+French/ }),
  ).toBeVisible();
  // A browser has no on-device engine: nothing to download.
  await expect(page.getByText(/can’t translate on its own/)).toBeVisible();

  await next.click();
  await expect(
    page.getByRole('heading', { name: /^Online translation/ }),
  ).toBeVisible();
  await expect(next).toBeHidden();
  await expect(page.getByRole('button', { name: 'Skip' })).toBeHidden();
  const aiLink = page.getByRole('button', { name: 'Open AI provider settings' });
  await scrollTo(page, aiLink);
  await expect(aiLink).toBeVisible();

  await page.getByRole('button', { name: 'Start translating' }).click();
  await expect(page.getByRole('tab', { name: 'Translate' })).toHaveAttribute(
    'aria-selected',
    'true',
  );
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
    // Privacy comes first; the other sections follow below it (scroll them
    // into the semantics tree).
    await expect(
      page.getByRole('heading', { name: 'Privacy', exact: true }),
    ).toBeVisible();
    for (const name of ['Offline languages', 'Online engines']) {
      const heading = page.getByRole('heading', { name, exact: true });
      await scrollTo(page, heading);
      await expect(heading).toBeVisible();
    }
    // The browser has no on-device engine.
    await expect(
      page.getByLabel(/On-device translation needs the Android app\./),
    ).toBeVisible();
    // AI providers are marked as advanced.
    const ai = page.getByRole('heading', { name: /^AI providers\s+Advanced/ });
    await scrollTo(page, ai);
    await expect(ai).toBeVisible();
    const providers = page.getByRole('button', { name: /^AI providers/ });
    await scrollTo(page, providers);
    await expect(providers).toBeVisible();
    const instantAi = page.getByRole('switch', {
      name: /^Instant translate with AI/,
    });
    await scrollTo(page, instantAi);
    await expect(instantAi).toBeVisible();
    for (const name of ['Appearance', 'About']) {
      const heading = page.getByRole('heading', { name, exact: true });
      await scrollTo(page, heading);
      await expect(heading).toBeVisible();
    }
    const licenses = page.getByRole('button', {
      name: /^Open-source licenses/,
    });
    await scrollTo(page, licenses);
    await expect(licenses).toHaveAccessibleName(/MPL-2\.0/);
  });

  test('quality modes', async ({ page }) => {
    await openApp(page, '/settings/quality');
    await expect(
      page.getByRole('heading', { name: 'Quality modes' }),
    ).toBeVisible();
    await expect(
      page.getByRole('heading', { name: 'Fast', exact: true }),
    ).toBeVisible();
    await expect(
      page.getByRole('heading', { name: 'Best', exact: true }),
    ).toBeVisible();
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

test('is served with a Content Security Policy', async ({ page }) => {
  await openApp(page, '/translate');
  const policy = await page
    .locator('meta[http-equiv="Content-Security-Policy"]')
    .getAttribute('content');
  expect(policy).toContain("script-src 'self' 'wasm-unsafe-eval'");
  expect(policy).not.toContain("'unsafe-eval'");
  // No inline scripts: the strict script-src would block them.
  expect(await page.locator('script:not([src])').count()).toBe(0);
});
