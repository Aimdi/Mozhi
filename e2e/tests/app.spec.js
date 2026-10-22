// Smoke tests: the app starts with its four tabs, History and Settings open
// from the app bar, the More tools menu opens and the main (including
// deferred, separately downloaded) routes render.
const { expect } = require('@playwright/test');
const {
  collectPageErrors,
  goBack,
  openApp,
  openHistory,
  openSettings,
  scrollTo,
  seedSettings,
  test,
  waitForSemantics,
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
  for (const tab of ['Dictionary', 'Proofread', 'Conversation']) {
    await expect(page.getByRole('tab', { name: tab })).toBeVisible();
  }
  // History and Settings are app bar buttons, not tabs.
  for (const name of ['History', 'Settings']) {
    await expect(
      page.getByRole('button', { name, exact: true }).first(),
    ).toBeVisible();
    await expect(page.getByRole('tab', { name })).toHaveCount(0);
  }
  await expect(
    page.getByRole('textbox', { name: 'Text to translate' }),
  ).toBeVisible();
  // Screen readers get the tree from the start: Flutter's hidden "Enable
  // accessibility" button is gone (lib/bootstrap.dart).
  await expect(page.locator('flt-semantics-placeholder')).toHaveCount(0);
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
  await waitForSemantics(page);

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

test('the tabs switch and keep History and Settings at hand', async ({
  page,
}) => {
  const errors = collectPageErrors(page);
  await openApp(page, '/translate');

  // Dictionary and Conversation are deferred: loaded on first open.
  await page.getByRole('tab', { name: 'Dictionary' }).click();
  await expect(
    page.getByRole('heading', { name: 'What does this mean?' }),
  ).toBeVisible();
  await page.getByRole('tab', { name: 'Proofread' }).click();
  await expect(
    page.getByRole('heading', { name: 'Does this look right?' }),
  ).toBeVisible();
  await page.getByRole('tab', { name: 'Conversation' }).click();
  await expect(page.getByRole('heading', { name: "Let's talk!" }))
    .toBeVisible();
  await expect(page.getByRole('tab', { name: 'Conversation' }))
    .toHaveAttribute('aria-selected', 'true');

  // History opens above the tabs; back returns to the same tab.
  await openHistory(page);
  await expect(page.getByRole('tab', { name: 'Conversation' })).toHaveCount(0);
  await goBack(page);
  await expect(page.getByRole('heading', { name: "Let's talk!" }))
    .toBeVisible();

  await openSettings(page);
  await goBack(page);
  await expect(page.getByRole('tab', { name: 'Conversation' }))
    .toHaveAttribute('aria-selected', 'true');
  expect(errors).toEqual([]);
});

test('More tools menu opens and closes', async ({ page }) => {
  await openApp(page, '/translate');
  await page.getByRole('button', { name: 'More tools' }).click();

  const menu = page.getByRole('menu');
  await expect(menu).toBeVisible();
  for (const item of ['Documents', 'Web page']) {
    await expect(menu.getByRole('menuitem', { name: item })).toBeVisible();
  }
  // The dictionary and conversation mode are tabs now.
  for (const item of ['Conversation', 'Dictionary']) {
    await expect(menu.getByRole('menuitem', { name: item })).toHaveCount(0);
  }

  await page.keyboard.press('Escape');
  await expect(menu).toBeHidden();
});

test.describe('routes render', () => {
  test('settings', async ({ page }) => {
    await openApp(page, '/settings');
    await expect(page.getByRole('heading', { name: 'Settings' })).toBeVisible();
    // A page above the tabs, with a way back even when opened on its own.
    await expect(page.getByRole('tab', { name: 'Translate' })).toHaveCount(0);
    await expect(
      page.getByRole('button', { name: 'Back', exact: true }),
    ).toBeVisible();
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
    // A tab of its own.
    await expect(page.getByRole('tab', { name: 'Dictionary' }))
      .toHaveAttribute('aria-selected', 'true');
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
