// Language pairs: the swap button swaps; a long press on it (or the More
// tools menu) lists the recently used pairs, which can be picked again.
// The language picker searches without diacritics.
const { expect } = require('@playwright/test');
const {
  copiedTranslation,
  fillField,
  openApp,
  seedSettings,
  test,
  typeSource,
} = require('./helpers');

// AI engine selected, "Instant translate with AI" off: every translation
// is started with the Translate button.
test.beforeEach(async ({ page }) => {
  await seedSettings(page, 'settings-ai-manual');
  await openApp(page, '/translate?text=Good%20night&from=en&to=de');
  await expect(
    page.getByRole('button', { name: 'Source language: English' }),
  ).toBeVisible();
  await expect(
    page.getByRole('button', { name: 'Target language: German' }),
  ).toBeVisible();
});

function swapButton(page) {
  return page.getByRole('button', { name: 'Swap languages' });
}

async function pressTranslate(page) {
  await page.getByRole('button', { name: 'Translate', exact: true }).click();
}

test('the swap button swaps the languages', async ({ page }) => {
  await swapButton(page).click();
  await expect(
    page.getByRole('button', { name: 'Source language: German' }),
  ).toBeVisible();
  await expect(
    page.getByRole('button', { name: 'Target language: English' }),
  ).toBeVisible();

  await swapButton(page).click();
  await expect(
    page.getByRole('button', { name: 'Source language: English' }),
  ).toBeVisible();
  await expect(
    page.getByRole('button', { name: 'Target language: German' }),
  ).toBeVisible();
});

test('recent pairs open with a long press and from the menu', async ({
  page,
}) => {
  // Nothing translated yet: no recent pairs.
  await swapButton(page).click({ delay: 1000 });
  const sheet = page.getByRole('group').filter({
    has: page.getByRole('heading', { name: 'Recent language pairs' }),
  });
  await expect(sheet).toBeVisible();
  await expect(
    page.getByText(/^No recent language pairs yet\./),
  ).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(sheet).toBeHidden();

  // Two translations: English → German, then (swapped) German → English.
  await pressTranslate(page);
  await expect
    .poll(() => copiedTranslation(page))
    .toBe('[AI→German (Deutsch)] Good night');
  await swapButton(page).click();
  await expect(
    page.getByRole('button', { name: 'Source language: German' }),
  ).toBeVisible();
  await typeSource(page, 'Gute Nacht');
  await pressTranslate(page);
  await expect
    .poll(() => copiedTranslation(page))
    .toMatch(/^\[AI→English.*\] Gute Nacht$/);

  // A long press on the swap button lists both, the newest (current) first.
  await swapButton(page).click({ delay: 1000 });
  await expect(sheet).toBeVisible();
  const current = sheet.getByRole('button', {
    name: /^From German to English/,
  });
  const earlier = sheet.getByRole('button', {
    name: /^From English to German/,
  });
  await expect(current).toBeVisible();
  await expect(earlier).toBeVisible();
  const order = await sheet
    .getByRole('button', { name: /^From / })
    .evaluateAll((nodes) =>
      nodes.map((n) => n.getAttribute('aria-label') ?? n.textContent),
    );
  expect(order).toHaveLength(2);
  expect(order[0]).toMatch(/^From German to English/);
  await page.keyboard.press('Escape');
  await expect(sheet).toBeHidden();

  // The More tools menu opens the same list; picking a pair applies it.
  await page.getByRole('button', { name: 'More tools' }).click();
  await page.getByRole('menuitem', { name: 'Recent language pairs' }).click();
  await expect(sheet).toBeVisible();
  await earlier.click();
  await expect(sheet).toBeHidden();
  await expect(
    page.getByRole('button', { name: 'Source language: English' }),
  ).toBeVisible();
  await expect(
    page.getByRole('button', { name: 'Target language: German' }),
  ).toBeVisible();
});

test('the picker finds a language without its diacritics', async ({
  page,
}) => {
  await page.getByRole('button', { name: 'Target language: German' }).click();
  await expect(
    page.getByRole('heading', { name: 'Translate to' }),
  ).toBeVisible();

  // "francais" finds French by its native name, Français.
  await fillField(page.getByRole('textbox', { name: /Search/ }), 'francais');
  const french = page.getByRole('button', { name: /^French/ }).first();
  await expect(french).toBeVisible();
  await french.click();

  await expect(
    page.getByRole('heading', { name: 'Translate to' }),
  ).toBeHidden();
  await expect(
    page.getByRole('button', { name: 'Target language: French' }),
  ).toBeVisible();
});

test('the picker closes without changing the language', async ({ page }) => {
  await page.getByRole('button', { name: 'Source language: English' }).click();
  await expect(
    page.getByRole('heading', { name: 'Translate from' }),
  ).toBeVisible();
  await page.getByRole('button', { name: 'Close' }).click();
  await expect(
    page.getByRole('heading', { name: 'Translate from' }),
  ).toBeHidden();
  await expect(
    page.getByRole('button', { name: 'Source language: English' }),
  ).toBeVisible();
});
