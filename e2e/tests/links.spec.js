// Kagi-style translate links (/translate?text=…&from=…&to=…) fill in the
// translate screen but never send a (possibly paid) AI request on their own.
const { expect } = require('@playwright/test');
const {
  copiedTranslation,
  openApp,
  recordAiRequests,
  seedSettings,
  sourceInput,
  test,
} = require('./helpers');

for (const [fixture, setting] of [
  ['settings-ai-manual', 'off'],
  ['settings-ai', 'on'],
]) {
  test(`a translate link prefills without an automatic AI request (instant AI ${setting})`, async ({ page }) => {
    // AI engine selected. Instant translate with AI ("Online engines and
    // AI") covers typing only, never a link, so neither setting may send a
    // request here.
    await seedSettings(page, fixture);
    const requests = recordAiRequests(page);

    await openApp(page, '/translate?text=Good%20night&from=en&to=de');

    await expect(
      page.getByRole('button', { name: 'Source language: English' }),
    ).toBeVisible();
    await expect(
      page.getByRole('button', { name: 'Target language: German' }),
    ).toBeVisible();
    await expect(page.getByText('10 characters')).toBeVisible();
    // Flutter web only mirrors a field's text into the DOM while it is being
    // edited: focus it to read the value.
    await sourceInput(page).click();
    await expect(sourceInput(page)).toHaveValue('Good night');
    const translateButton = page.getByRole('button', {
      name: 'Translate',
      exact: true,
    });
    await expect(translateButton).toBeVisible();

    // Give a (wrong) automatic request time to go out (longer than the
    // instant-translate debounce); none may. Proving an absence needs a
    // bounded wait.
    await page.waitForLoadState('networkidle');
    await page.waitForTimeout(2000);
    expect(requests).toEqual([]);

    // Pressing Translate sends exactly one request and shows the result.
    await translateButton.click();
    await expect
      .poll(() => copiedTranslation(page))
      .toBe('[AI→German (Deutsch)] Good night');
    expect(requests).toHaveLength(1);
  });
}
