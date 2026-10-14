// History: translations are saved on the device and can be starred,
// searched and deleted (with Undo).
const { expect } = require('@playwright/test');
const {
  collectPageErrors,
  copiedTranslation,
  fillField,
  openApp,
  seedSettings,
  sourceInput,
  test,
  typeSource,
} = require('./helpers');

// Texts the mock doesn't look up in its dictionary, so it answers
// "[AI→French (Français)] <text>".
const FIRST = 'Good evening';
const SECOND = 'See you tomorrow';

test.beforeEach(async ({ page }) => {
  await seedSettings(page, 'settings-ai');
  await openApp(page, '/translate');
});

/** Types [text] and waits until its AI translation is shown. */
async function translate(page, text) {
  await typeSource(page, text);
  await expect
    .poll(() => copiedTranslation(page))
    .toBe(`[AI→French (Français)] ${text}`);
}

/** The history entry whose label mentions [text]. */
function entry(page, text) {
  return page.getByRole('group', { name: new RegExp(`→ .*${text}`) });
}

test('a translation appears in History and can be starred', async ({
  page,
}) => {
  const errors = collectPageErrors(page);
  await translate(page, FIRST);
  await page.getByRole('tab', { name: 'History' }).click();

  const item = entry(page, FIRST);
  await expect(item).toBeVisible();
  await expect(item).toHaveAccessibleName(
    new RegExp(
      `^.*English \\(detected\\).* → .*French.* ${FIRST} ` +
        `\\[AI→French \\(Français\\)\\] ${FIRST} Local AI \\(mock\\) · `,
    ),
  );

  // Nothing is starred yet.
  const favourites = page.getByRole('checkbox', { name: 'Favorites' });
  await favourites.click();
  await expect(page.getByRole('heading', { name: /^No favorites yet/ }))
    .toBeVisible();
  await expect(item).toBeHidden();
  await page.getByRole('checkbox', { name: 'All' }).click();

  // Star it: it shows under Favorites.
  await item.getByRole('button', { name: 'Add to favorites' }).click();
  await expect(
    item.getByRole('button', { name: 'Remove from favorites' }),
  ).toBeVisible();
  await favourites.click();
  await expect(favourites).toBeChecked();
  await expect(item).toBeVisible();

  // Unstar it: Favorites is empty again.
  await item.getByRole('button', { name: 'Remove from favorites' }).click();
  await expect(page.getByRole('heading', { name: /^No favorites yet/ }))
    .toBeVisible();
  expect(errors).toEqual([]);
});

test('search filters the history', async ({ page }) => {
  await translate(page, FIRST);
  await page.getByRole('button', { name: 'Clear' }).click();
  await expect(sourceInput(page)).toBeVisible();
  await translate(page, SECOND);
  await page.getByRole('tab', { name: 'History' }).click();

  await expect(entry(page, FIRST)).toBeVisible();
  await expect(entry(page, SECOND)).toBeVisible();

  const search = page.getByRole('searchbox', { name: 'Search history' });
  await fillField(search, 'tomorrow');
  await expect(entry(page, SECOND)).toBeVisible();
  await expect(entry(page, FIRST)).toBeHidden();

  await fillField(search, 'nothing like this');
  await expect(page.getByRole('heading', { name: /^No matches/ }))
    .toBeVisible();
  await expect(entry(page, SECOND)).toBeHidden();

  await fillField(search, '');
  await expect(entry(page, FIRST)).toBeVisible();
  await expect(entry(page, SECOND)).toBeVisible();
});

test('a deleted entry comes back with Undo', async ({ page }) => {
  await translate(page, FIRST);
  await page.getByRole('tab', { name: 'History' }).click();
  const item = entry(page, FIRST);
  await expect(item).toBeVisible();

  await item.getByRole('button', { name: 'More actions' }).click();
  await page.getByRole('menuitem', { name: 'Delete' }).click();

  const snackBar = page.getByRole('group', { name: 'Translation deleted' });
  await expect(snackBar).toBeVisible();
  await expect(item).toBeHidden();
  await expect(page.getByRole('heading', { name: /^No history yet/ }))
    .toBeVisible();

  await snackBar.getByRole('button', { name: 'Undo' }).click();
  await expect(item).toBeVisible();

  // The restored entry is stored again: it survives a reload.
  await page.reload();
  await openApp(page, '/history');
  await expect(entry(page, FIRST)).toBeVisible();
});
