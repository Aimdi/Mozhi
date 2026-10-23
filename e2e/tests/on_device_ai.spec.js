// On-device AI (llama.cpp, packages/llama_engine) runs only in the Android
// app for now: the web app's On-device AI page says so, offers nothing to
// download, and the app never contacts a model host by itself.
const { expect } = require('@playwright/test');
const {
  collectPageErrors,
  openApp,
  seedSettings,
  test,
} = require('./helpers');

test.beforeEach(async ({ page }) => {
  await seedSettings(page, 'settings-ai');
});

test('the On-device AI page says it needs the Android app', async ({
  page,
}) => {
  const errors = collectPageErrors(page);
  const modelHosts = [];
  page.on('request', (request) => {
    const { hostname, pathname } = new URL(request.url());
    if (hostname.endsWith('huggingface.co') || pathname.includes('/llm/')) {
      modelHosts.push(request.url());
    }
  });

  await openApp(page, '/settings/on-device-ai');
  await expect(
    page.getByRole('heading', { name: 'On-device AI' }),
  ).toBeVisible();
  await expect(
    page.getByText('On-device AI needs the Android app.').first(),
  ).toBeVisible();
  // No model to download or import in a browser.
  await expect(page.getByRole('button', { name: /^Download/ })).toHaveCount(0);

  expect(modelHosts).toEqual([]);
  expect(errors).toEqual([]);
});
