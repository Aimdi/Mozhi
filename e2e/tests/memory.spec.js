// Translation memory: text translated before is offered from the history
// ("From your history"), and using it sends nothing to the AI provider.
const { test, expect } = require('@playwright/test');
const {
  copiedTranslation,
  openApp,
  recordAiRequests,
  seedSettings,
  typeSource,
} = require('./helpers');

const TEXT = 'Good evening';
const TRANSLATION = `[AI→French (Français)] ${TEXT}`;

test('an earlier translation is offered and can be used', async ({
  page,
}) => {
  // "Instant translate with AI" off, so the offer stays up until used.
  await seedSettings(page, 'settings-ai-manual');
  const requests = recordAiRequests(page);
  await openApp(page, '/translate');

  const memory = page.getByRole('group', {
    name: 'From your history',
    exact: true,
  });
  await typeSource(page, TEXT);
  // Nothing in the history yet.
  await expect(memory).toBeHidden();
  await page.getByRole('button', { name: 'Translate', exact: true }).click();
  await expect.poll(() => copiedTranslation(page)).toBe(TRANSLATION);
  expect(requests).toHaveLength(1);

  await page.getByRole('button', { name: 'Clear' }).click();
  await expect(memory).toBeHidden();
  await typeSource(page, TEXT);

  await expect(memory).toBeVisible();
  await expect(memory).toContainText(TRANSLATION);
  await expect(memory).toContainText('Local AI (mock)');

  await memory
    .getByRole('button', { name: 'Use the translation from your history' })
    .click();
  await expect(memory).toBeHidden();
  await expect.poll(() => copiedTranslation(page)).toBe(TRANSLATION);
  // Taken from the history, not translated again.
  expect(requests).toHaveLength(1);
});
