// Phrasebook: a translation goes into a new collection with "Add to
// phrasebook…", the phrasebook (from More tools) lists the collection with
// the phrase, and the collection is exported as a CSV file for Anki and
// spreadsheets (a download in the web app).
const fs = require('node:fs');
const { expect } = require('@playwright/test');
const {
  collectPageErrors,
  copiedTranslation,
  fillField,
  openApp,
  seedSettings,
  test,
  typeSource,
} = require('./helpers');

// A phrase the mock really translates: an echo of the English text would be
// flagged as the wrong language and translated by another engine.
const TEXT = 'Thank you';
const TRANSLATION = 'merci';
const COLLECTION = 'Trip to Lisbon';

test.beforeEach(async ({ page }) => {
  await seedSettings(page, 'settings-ai');
  await openApp(page, '/translate');
});

test('a translation goes into a new collection, which exports as CSV', async ({
  page,
}) => {
  const errors = collectPageErrors(page);
  await typeSource(page, TEXT);
  await expect.poll(() => copiedTranslation(page)).toBe(TRANSLATION);

  // Beside the heart: into a new collection.
  await page.getByRole('button', { name: 'Add to phrasebook…' }).click();
  const sheet = page.getByRole('group').filter({
    has: page.getByRole('heading', { name: 'Add to phrasebook' }),
  });
  await expect(sheet).toBeVisible();
  await sheet.getByRole('button', { name: 'New collection' }).click();
  const name = page.getByRole('textbox', { name: /^Name/ });
  await fillField(name, COLLECTION);
  await page.getByRole('button', { name: 'Create' }).click();
  // A snack bar with an action is a group named by its message.
  await expect(
    page.getByRole('group', { name: `Added to ${COLLECTION}` }),
  ).toBeVisible();

  // The phrasebook lists it, from More tools.
  await page.getByRole('button', { name: 'More tools' }).click();
  await page.getByRole('menuitem', { name: 'Phrasebook' }).click();
  await expect(page.getByRole('heading', { name: 'Your collections' }))
    .toBeVisible();
  const row = page.getByRole('button', { name: new RegExp(COLLECTION) });
  await expect(row).toBeVisible();
  await expect(row).toHaveAccessibleName(/1 phrase/);
  await row.click();
  // The phrase and its translation read as one row.
  await expect(
    page.getByText(new RegExp(`^${TEXT}\\s+${TRANSLATION}$`)),
  ).toBeVisible();
  await expect(
    page.getByRole('button', { name: 'Listen to the translation' }),
  ).toBeVisible();

  // Export as CSV: a download with Anki's header and the phrase.
  await page.getByRole('button', { name: 'Collection actions' }).click();
  await page.getByRole('menuitem', { name: 'Export as CSV' }).click();
  await expect(page.getByRole('heading', { name: 'Export 1 phrase' }))
    .toBeVisible();
  const download = page.waitForEvent('download');
  await page.getByRole('button', { name: 'Save as CSV' }).click();
  const file = await download;
  expect(file.suggestedFilename()).toBe('mozhi-Trip-to-Lisbon.csv');
  const path = test.info().outputPath(file.suggestedFilename());
  await file.saveAs(path);
  const csv = fs.readFileSync(path, 'utf8').replace(/^﻿/, '');
  expect(csv.startsWith('#separator:Comma\r\n#html:false\r\n')).toBe(true);
  expect(csv).toContain(`${TEXT},${TRANSLATION},English,French,`);
  // The snack bar, and its announcement for screen readers.
  await expect(page.getByText('Saved 1 phrase').first()).toBeVisible();
  expect(errors).toEqual([]);
});
