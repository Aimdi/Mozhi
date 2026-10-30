// No network: with the AI provider and the Mozhi instance unreachable (or
// the browser offline) the app shows a friendly error – a short title, then
// the explanation – instead of crashing, and recovers once they are back.
const { expect } = require('@playwright/test');
const {
  collectPageErrors,
  copiedTranslation,
  goBack,
  openApp,
  openHistory,
  seedSettings,
  takeMockDown,
  test,
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
  const error = page.getByRole('group', {
    name: "Couldn't reach the AI provider. Check your connection and the server URL.",
  });
  await expect(error).toBeVisible();
  await expect(error).toHaveAccessibleName(
    /^Couldn’t connect\s+Couldn't reach the AI provider\./,
  );
  await expect(page.getByRole('button', { name: 'Copy', exact: true }))
    .toBeHidden();

  // The app still works: other pages open and the input is kept.
  await openHistory(page);
  await goBack(page);
  await expect(
    page.getByRole('textbox', { name: 'Text to translate' }),
  ).toBeVisible();

  // Back online: Retry translates.
  await page.unrouteAll();
  await error.getByRole('button', { name: 'Retry' }).click();
  await expect(error).toBeHidden();
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
  await openApp(page, '/translate');
  // The instance answers until its engines are loaded, then goes down.
  await expect(
    page
      .getByRole('banner', { name: 'Choose translation engine' })
      .getByRole('button', { name: /^Google/ }),
  ).toBeVisible();
  await takeMockDown(page);

  await typeSource(page, 'Good evening');
  // Every server failed: a plain explanation, never an HTTP status.
  const error = page.getByRole('group', {
    name: /^Volunteer servers unavailable\s+The volunteer server couldn.t translate with Google just now\./,
  });
  await expect(error).toBeVisible();
  await expect(error).not.toHaveAccessibleName(/HTTP|\b5\d\d\b/);
  // Retry, another engine (the AI provider) and another server.
  for (const name of ['Retry', 'Try another engine', 'Choose another server']) {
    await expect(error.getByRole('button', { name })).toBeVisible();
  }
  expect(errors).toEqual([]);
});

test('without a network the error says the browser is offline', async ({
  page,
}) => {
  await seedSettings(page, 'settings-ai');
  const errors = collectPageErrors(page);
  await openApp(page, '/translate');
  await page.context().setOffline(true);

  await typeSource(page, 'Good evening');
  const error = page.getByRole('group', {
    name: /^You’re offline\s+Connect to the internet, then try again\.$/,
  });
  await expect(error).toBeVisible();

  // Back online: Retry translates.
  await page.context().setOffline(false);
  await error.getByRole('button', { name: 'Retry' }).click();
  await expect(error).toBeHidden();
  await expect
    .poll(() => copiedTranslation(page))
    .toBe('[AI→French (Français)] Good evening');
  expect(errors).toEqual([]);
});
