// History: translations are saved on the device as compact rows, and can be
// liked, copied, searched, filtered by language pair and deleted (with
// Undo); the engine and time are in an entry's details, and the favorites
// are a phrasebook grouped by language pair.
const { expect } = require('@playwright/test');
const {
  collectPageErrors,
  copiedTranslation,
  escapeRegExp,
  fillField,
  openApp,
  openHistory,
  recordAiRequests,
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

/**
 * The history entry whose source text is [text].
 *
 * A row is named by its source, its translation and its language pair –
 * but while the pointer is on it, the row shows its Copy, Share and Delete
 * buttons in place of the pair, so the entry is found by its first line.
 */
function entry(page, text) {
  return page.getByRole('group', {
    name: new RegExp(`^${escapeRegExp(text)}\\s`),
  });
}

test('a translation appears in History and can be liked', async ({
  page,
}) => {
  const errors = collectPageErrors(page);
  await translate(page, FIRST);
  await openHistory(page);

  const item = entry(page, FIRST);
  await expect(item).toBeVisible();
  // Two lines (the source, its translation), then the pair tag, read as
  // the whole pair (the language names bidi-isolated).
  await expect(item).toHaveAccessibleName(
    new RegExp(
      `^${FIRST}\\s+\\[AI→French \\(Français\\)\\] ${FIRST}\\s+` +
        '\\S*English \\(detected\\)\\S* → \\S*French\\S*$',
    ),
  );

  // The engine and the time are in the entry's details (its menu also
  // has the row's other actions).
  await item.getByRole('button', { name: 'More actions' }).click();
  const menu = page.getByRole('menu');
  for (const name of [
    'Copy',
    'Share',
    'Details',
    'Add to favorites',
    'Delete',
  ]) {
    await expect(menu.getByRole('menuitem', { name })).toBeVisible();
  }
  await menu.getByRole('menuitem', { name: 'Details' }).click();
  const details = page.getByRole('group').filter({
    has: page.getByRole('heading', {
      name: /^\S*English \(detected\)\S* → \S*French\S*$/,
    }),
  });
  await expect(details).toBeVisible();
  // (The text of the nodes, joined without spaces.)
  await expect(details).toContainText(/Local AI \(mock\) · \S/);
  await expect(details).toContainText(
    new RegExp(
      `Original\\s*${FIRST}\\s*` +
        `Translation\\s*\\[AI→French \\(Français\\)\\] ${FIRST}`,
    ),
  );
  await expect(
    details.getByRole('button', { name: 'Open in translator' }),
  ).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(details).toBeHidden();

  // Nothing is liked yet. The filters are tabs.
  const favourites = page.getByRole('tab', { name: 'Favorites' });
  await favourites.click();
  await expect(page.getByRole('heading', { name: /^No favorites yet/ }))
    .toBeVisible();
  await expect(item).toBeHidden();
  await page.getByRole('tab', { name: 'All' }).click();

  // With a mouse on the row, Copy, Share and Delete take the pair's place;
  // Copy shows a check for a moment.
  await item.hover();
  for (const name of [/^Share/, /^Delete/]) {
    await expect(item.getByRole('button', { name })).toBeVisible();
  }
  await page.evaluate(() => navigator.clipboard.writeText(''));
  await item.getByRole('button', { name: /^Copy( Copy)?$/ }).click();
  await expect(
    item.getByRole('button', { name: /^Copied to clipboard/ }),
  ).toBeVisible();
  expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(
    `[AI→French (Français)] ${FIRST}`,
  );

  // Like it (a heart): it shows under Favorites, in its language pair's
  // group, and the favorites can be exported.
  await item.getByRole('button', { name: 'Add to favorites' }).click();
  await expect(
    item.getByRole('button', { name: 'Remove from favorites' }),
  ).toBeVisible();
  await favourites.click();
  await expect(favourites).toHaveAttribute('aria-selected', 'true');
  await expect(item).toBeVisible();
  await expect(
    page.getByRole('heading', {
      name: /^\S*English\S* → \S*French\S* · 1 translation$/,
    }),
  ).toBeVisible();
  await expect(
    page.getByRole('button', { name: 'Export favorites' }),
  ).toBeVisible();

  // Unlike it: Favorites is empty again.
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
  await openHistory(page);

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
  await openHistory(page);
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

test('the language pair filter narrows the history', async ({ page }) => {
  await translate(page, FIRST);
  // Swapping moves the finished translation into the input and translates
  // it back: a second, French → English entry.
  await page.getByRole('button', { name: 'Swap languages' }).click();
  await expect(
    page.getByRole('button', { name: 'Target language: English' }),
  ).toBeVisible();
  await expect.poll(() => copiedTranslation(page)).toMatch(/^\[AI→English/);
  await openHistory(page);

  const english = entry(page, FIRST);
  const french = entry(page, `[AI→French (Français)] ${FIRST}`);
  await expect(english).toBeVisible();
  await expect(french).toBeVisible();
  await expect(english).toHaveAccessibleName(
    /\S*English \(detected\)\S* → \S*French\S*$/,
  );
  await expect(french).toHaveAccessibleName(/\S*French\S* → \S*English\S*$/);

  const pairs = page.getByRole('button', { name: /All language pairs/ });
  await pairs.click();
  const sheet = page.getByRole('group').filter({
    has: page.getByRole('heading', { name: 'Language pair' }),
  });
  await expect(sheet).toBeVisible();
  await sheet.getByRole('button', { name: /French.*→.*English/ }).click();
  await expect(sheet).toBeHidden();
  await expect(english).toBeHidden();
  await expect(french).toBeVisible();

  await page.getByRole('button', { name: 'Clear filters' }).click();
  await expect(english).toBeVisible();
  await expect(pairs).toBeVisible();

  // The favorites are a phrasebook: grouped by language pair, with chips
  // that show one pair.
  for (const item of [english, french]) {
    await item.getByRole('button', { name: 'Add to favorites' }).click();
    await expect(
      item.getByRole('button', { name: 'Remove from favorites' }),
    ).toBeVisible();
  }
  await page.getByRole('tab', { name: 'Favorites' }).click();
  const chips = page.getByRole('group', { name: 'Language pairs' });
  const all = chips.getByRole('checkbox', { name: 'All', exact: true });
  await expect(all).toBeChecked();
  await expect(english).toBeVisible();
  await expect(french).toBeVisible();
  const frenchChip = chips.getByRole('checkbox', {
    name: /^\S*French\S* → \S*English\S*$/,
  });
  await frenchChip.click();
  await expect(frenchChip).toBeChecked();
  await expect(english).toBeHidden();
  await expect(french).toBeVisible();
  await all.click();
  await expect(all).toBeChecked();
  await expect(english).toBeVisible();
  await expect(french).toBeVisible();
});

test('a link opens History on the Favorites tab', async ({ page }) => {
  await translate(page, FIRST);
  await openHistory(page);
  await expect(entry(page, FIRST)).toBeVisible();

  // What a long press on the History button opens.
  await page.reload();
  await openApp(page, '/history?tab=favorites');

  const favourites = page.getByRole('tab', { name: 'Favorites' });
  await expect(favourites).toHaveAttribute('aria-selected', 'true');
  await expect(page.getByRole('heading', { name: /^No favorites yet/ }))
    .toBeVisible();
  await expect(entry(page, FIRST)).toBeHidden();

  await page.getByRole('tab', { name: 'All' }).click();
  await expect(entry(page, FIRST)).toBeVisible();
});

test('a dictionary look-up is saved to History, liked and opened again', async ({
  page,
}) => {
  const errors = collectPageErrors(page);
  const requests = recordAiRequests(page);
  // As the other link tests here: reload, then open the link.
  await page.reload();
  await openApp(page, '/dictionary?word=hello&from=en&to=fr');
  await page.getByRole('button', { name: 'Look up' }).click();

  // The entry: its tabs, the search bar still on top, and the heart beside
  // Listen, which works once the entry is shown.
  const heart = page.getByRole('button', { name: 'Add to favorites' });
  await expect(heart).toBeEnabled();
  await expect.poll(() => requests.length).toBe(1);
  await expect(page.getByRole('heading', { name: 'hello' })).toBeVisible();
  for (const name of ['Meaning', 'Usage', 'Examples']) {
    await expect(page.getByRole('tab', { name })).toBeVisible();
  }
  await expect(
    page.getByRole('textbox', { name: /^Look up a word or phrase/ }),
  ).toBeVisible();
  await expect(page.getByRole('button', { name: 'Listen' })).toBeVisible();
  await heart.click();
  await expect(
    page.getByRole('button', { name: 'Remove from favorites' }),
  ).toBeVisible();

  // History lists it as a look-up: the marker, the word, the mock entry's
  // summary and the language pair.
  await openHistory(page);
  const item = page.getByRole('group', { name: /^Dictionary\s+hello\s/ });
  await expect(item).toBeVisible();
  await expect(item).toHaveAccessibleName(
    /^Dictionary\s+hello\s+interjection · used as a greeting\s+\S*English\S* → \S*French\S*$/,
  );
  await page.getByRole('tab', { name: 'Favorites' }).click();
  await expect(item).toBeVisible();

  // Opening it looks the word up again on the Dictionary tab.
  await item.click();
  await expect(page.getByRole('tab', { name: 'Dictionary' }))
    .toHaveAttribute('aria-selected', 'true');
  await expect.poll(() => requests.length).toBe(2);
  await expect(
    page.getByRole('button', { name: 'Remove from favorites' }),
  ).toBeEnabled();
  expect(errors).toEqual([]);
});
