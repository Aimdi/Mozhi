// Smoke tests: the app starts with its four tabs, the first run on the web,
// History and Settings open from the app bar, the More tools menu opens and
// the main (including deferred, separately downloaded) routes render.
const { expect } = require('@playwright/test');
const {
  collectPageErrors,
  escapeRegExp,
  goBack,
  openApp,
  openHistory,
  openSettings,
  openSettingsCategory,
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
  // The seeded AI provider is the selected engine; the app bar names it
  // without its model id (that is in the engine sheet).
  await expect(
    page.getByRole('button', { name: /Local AI \(mock\)/ }).first(),
  ).toBeVisible();
  await expect(page.getByText(/mock-translator-8b/)).toHaveCount(0);
  expect(errors).toEqual([]);
});

test('first run in a browser without the on-device engine: three steps, no privacy step', async ({
  page,
}) => {
  const errors = collectPageErrors(page);
  // As in a browser that can't run the engine (or a build without it):
  // the engine's worker doesn't load, so the app has no on-device engine.
  await page.route('**/bergamot/worker.js', (route) =>
    route.fulfill({ status: 404, body: '' }),
  );
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
  await expect(page.getByText('Step 1 of 3', { exact: true })).toBeVisible();
  const next = page.getByRole('button', { name: 'Next' });
  // Without an on-device engine there is no privacy step: its choice is
  // one switch on the service step.
  const privacyStep = page.getByRole('heading', {
    name: 'How private should translations be?',
  });

  await next.click();
  await expect(
    page.getByRole('heading', { name: 'Pick your languages' }),
  ).toBeVisible();
  await expect(page.getByText('Step 2 of 3', { exact: true })).toBeVisible();
  await expect(privacyStep).toHaveCount(0);
  await expect(
    page.getByRole('button', { name: /^Translate into\s+French/ }),
  ).toBeVisible();
  // Nothing to download.
  await expect(page.getByText(/can’t translate on its own/)).toBeVisible();

  await next.click();
  await expect(
    page.getByRole('heading', { name: /^Online translation/ }),
  ).toBeVisible();
  await expect(page.getByText('Step 3 of 3', { exact: true })).toBeVisible();
  await expect(privacyStep).toHaveCount(0);
  await expect(next).toBeHidden();
  await expect(page.getByRole('button', { name: 'Skip' })).toBeHidden();
  // The online service is the only engine here: not "Optional".
  await expect(page.getByText('Optional', { exact: true })).toHaveCount(0);

  // The server in use, with the list of servers behind "Change".
  const server = page.getByRole('group', {
    name: /^Using Local test instance/,
  });
  await expect(server).toBeVisible();
  await expect(page.getByRole('radio')).toHaveCount(0);
  await server.getByRole('button', { name: 'Change' }).click();
  const instance = page.getByRole('radio', { name: /^Local test instance/ });
  await expect(instance).toBeChecked();
  await server.getByRole('button', { name: 'Done' }).click();
  await expect(instance).toHaveCount(0);
  // One button measures the servers' speed (they are contacted only then).
  await page.getByRole('button', { name: /^Find the fastest server/ }).click();
  await expect(page.getByRole('button', { name: /^Test again/ })).toBeVisible();

  // In a browser text goes online without asking unless this is turned
  // on (Offline first).
  const ask = page.getByRole('switch', { name: /^Ask before sending text/ });
  await expect(ask).not.toBeChecked();
  await ask.click();
  await expect(ask).toBeChecked();

  const aiLink = page.getByRole('button', { name: 'Open AI provider settings' });
  await scrollTo(page, aiLink);
  await expect(aiLink).toBeVisible();

  await page.getByRole('button', { name: 'Start translating' }).click();
  await expect(page.getByRole('tab', { name: 'Translate' })).toHaveAttribute(
    'aria-selected',
    'true',
  );
  // The switch chose the privacy mode.
  await openSettings(page);
  await openSettingsCategory(page, 'Privacy & data');
  await expect(
    page
      .getByRole('group', { name: 'Privacy mode' })
      .getByRole('radio', { name: /^Offline first/ }),
  ).toBeChecked();
  expect(errors).toEqual([]);
});

test('first run with the on-device engine: the privacy step and downloads', async ({
  page,
}) => {
  const errors = collectPageErrors(page);
  await openApp(page, '/translate');
  await page.evaluate(() => {
    const settings = JSON.parse(JSON.parse(localStorage.getItem('settings.v1')));
    settings.onboardingComplete = false;
    localStorage.setItem('settings.v1', JSON.stringify(JSON.stringify(settings)));
  });
  await page.reload();
  await waitForSemantics(page);

  // The browser runs Mozilla's engine (web/bergamot/): the same four steps
  // as the Android app.
  await expect(page.getByText('Step 1 of 4', { exact: true })).toBeVisible();
  const next = page.getByRole('button', { name: 'Next' });
  await next.click();
  await expect(
    page.getByRole('heading', { name: 'How private should translations be?' }),
  ).toBeVisible();
  await expect(page.getByText('Step 2 of 4', { exact: true })).toBeVisible();
  await expect(
    page.getByRole('radio', { name: /^Offline only/ }),
  ).toBeVisible();

  await next.click();
  await expect(
    page.getByRole('heading', { name: 'Pick your languages' }),
  ).toBeVisible();
  // The target language can be downloaded for offline use (nothing is
  // downloaded unless asked).
  await expect(
    page.getByRole('banner', { name: /^Download French/ }),
  ).toBeVisible();
  await expect(page.getByText(/can’t translate on its own/)).toHaveCount(0);

  await next.click();
  await expect(
    page.getByRole('heading', { name: /^Online translation\s+Optional/ }),
  ).toBeVisible();
  await expect(page.getByText('Step 4 of 4', { exact: true })).toBeVisible();
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
    page.getByRole('heading', { name: 'Look up a word' }),
  ).toBeVisible();
  await page.getByRole('tab', { name: 'Proofread' }).click();
  await expect(
    page.getByRole('heading', { name: 'Check your writing' }),
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
  for (const item of ['Documents', 'Web page', 'Recent language pairs']) {
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
    // A search field, then the categories in this order, each with a
    // summary; AI is marked as advanced.
    await expect(
      page.getByRole('searchbox', { name: 'Search settings' }),
    ).toBeVisible();
    const categories = [
      'General',
      'Privacy & data',
      'Translation engines',
      'AI',
      'Appearance',
      'Read aloud & voice',
      'About',
    ];
    const listed = page.getByRole('button', {
      name: new RegExp(`^(${categories.join('|')}) `),
    });
    await expect(listed).toHaveCount(categories.length);
    for (const [index, name] of categories.entries()) {
      await expect(listed.nth(index)).toHaveAccessibleName(
        new RegExp(`^${escapeRegExp(name)} `),
      );
    }
    await expect(
      page.getByRole('button', { name: /^AI\s+Advanced\s+AI providers/ }),
    ).toBeVisible();

    // Each category is a page of its own; back returns to the list.
    // Privacy & data: four groups, the destructive actions last.
    await openSettingsCategory(page, 'Privacy & data');
    const privacyGroups = ['Privacy', 'History', 'Network', 'Data'];
    for (const name of privacyGroups) {
      const heading = page.getByRole('heading', { name, exact: true });
      await scrollTo(page, heading);
      await expect(heading).toBeVisible();
    }
    const groups = page.getByRole('heading', {
      name: new RegExp(`^(${privacyGroups.join('|')})$`),
    });
    await expect(groups).toHaveCount(privacyGroups.length);
    for (const [index, name] of privacyGroups.entries()) {
      await expect(groups.nth(index)).toHaveAccessibleName(name);
    }
    await expect(
      page.getByRole('button', { name: /^Delete all local data/ }),
    ).toBeVisible();
    await goBack(page);

    // Translation engines: the offline languages, the online engines and
    // how they translate.
    await openSettingsCategory(page, 'Translation engines');
    for (const name of ['Offline languages', 'Online engines', 'Translating']) {
      const heading = page.getByRole('heading', { name, exact: true });
      await scrollTo(page, heading);
      await expect(heading).toBeVisible();
    }
    // The web app translates on the device too (WebAssembly).
    const offlineLanguages = page.getByRole('button', {
      name: /^Languages on this device/,
    });
    await scrollTo(page, offlineLanguages);
    await expect(offlineLanguages).toBeVisible();
    // Instant translation is one setting with three choices.
    const instant = page.getByRole('button', {
      name: /^Instant translate\s+Online engines and AI$/,
    });
    await scrollTo(page, instant);
    await instant.click();
    const dialog = page.getByRole('alertdialog');
    await expect(dialog).toBeVisible();
    await expect(dialog.getByRole('radio')).toHaveCount(3);
    for (const name of [/^Off /, /^Online engines Mozhi/]) {
      await expect(dialog.getByRole('radio', { name })).not.toBeChecked();
    }
    await expect(
      dialog.getByRole('radio', { name: /^Online engines and AI / }),
    ).toBeChecked();
    await dialog.getByRole('button', { name: 'Cancel' }).click();
    await expect(dialog).toBeHidden();
    await goBack(page);

    // AI, marked as advanced: the providers come first.
    await openSettingsCategory(page, 'AI');
    await expect(
      page.getByRole('heading', { name: /^AI\s+Advanced$/ }),
    ).toBeVisible();
    await expect(
      page.getByRole('button', { name: /^AI providers\s+1 of 1 enabled/ }),
    ).toBeVisible();
    await goBack(page);

    await openSettingsCategory(page, 'Appearance');
    await expect(
      page.getByRole('group', { name: 'Theme', exact: true }),
    ).toBeVisible();
    await goBack(page);

    // About, with the licenses.
    await openSettingsCategory(page, 'About');
    const licenses = page.getByRole('button', {
      name: /^Open-source licenses/,
    });
    await scrollTo(page, licenses);
    await expect(licenses).toHaveAccessibleName(/MPL-2\.0/);
    await goBack(page);
    await expect(page.getByRole('heading', { name: 'Settings' })).toBeVisible();
    await expect(
      page.getByRole('searchbox', { name: 'Search settings' }),
    ).toBeVisible();
  });

  test('settings on a wide screen: the list beside the category', async ({
    page,
  }) => {
    await page.setViewportSize({ width: 1280, height: 900 });
    await openApp(page, '/settings');
    await expect(page.getByRole('heading', { name: 'Settings' })).toBeVisible();
    // General is shown beside the list.
    await expect(
      page.getByRole('heading', { name: 'General', exact: true }),
    ).toBeVisible();
    await expect(
      page.getByRole('button', { name: /^App language/ }),
    ).toBeVisible();
    // Picking a category changes the pane, not the location.
    await page.getByRole('button', { name: /^Appearance / }).click();
    await expect(
      page.getByRole('heading', { name: 'Appearance', exact: true }),
    ).toBeVisible();
    await expect(
      page.getByRole('group', { name: 'Theme', exact: true }),
    ).toBeVisible();
    await expect(
      page.getByRole('button', { name: /^General / }),
    ).toBeVisible();
    expect(new URL(page.url()).hash).toBe('#/settings');
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
    await expect(
      page.getByRole('heading', { name: 'Look up a word' }),
    ).toBeVisible();
    // A tab of its own; on a phone the app bar shows the AI model (which
    // opens the model choice) instead of a title.
    await expect(page.getByRole('tab', { name: 'Dictionary' }))
      .toHaveAttribute('aria-selected', 'true');
    await expect(
      page
        .getByRole('banner')
        .getByRole('button', { name: 'AI model: Local AI (mock)' }),
    ).toBeVisible();
    // The word is filled in (Flutter web mirrors a field's text into the
    // DOM while it is being edited: focus it to read the value).
    const word = page.getByRole('textbox', { name: /^Look up a word or phrase/ });
    await word.click();
    await expect(word).toHaveValue('hello');
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
