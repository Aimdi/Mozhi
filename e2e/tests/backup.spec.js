// Encrypted backup: a backup made in the web app is downloaded as one
// .mozhibackup file, survives clearing the site's data, and restores the
// history through the browser's file chooser (Settings > Backup & sync).
const fs = require('node:fs');
const { expect } = require('@playwright/test');
const {
  collectPageErrors,
  copiedTranslation,
  escapeRegExp,
  fillField,
  openApp,
  seedSettings,
  test,
  typeSource,
} = require('./helpers');

// The mock answers "[AI→French (Français)] <text>" for texts it doesn't
// look up in its dictionary.
const TEXT = 'See you at the station';
const PASSPHRASE = 'correct horse battery staple';

// Argon2id runs as JavaScript in the browser (19 MiB, 2 passes): a few
// seconds on a slow CI runner.
const CRYPTO_TIMEOUT = 60_000;

/** The history entry whose source text is [text] (see history.spec.js). */
function entry(page, text) {
  return page.getByRole('group', {
    name: new RegExp(`^${escapeRegExp(text)}\\s`),
  });
}

/**
 * The open backup or restore dialog (texts it announces are also copied
 * into the page's live region, outside the dialog).
 */
function dialog(page) {
  return page.getByRole('dialog');
}

/** A settings row (a list tile) whose title is [title]. */
function row(page, title) {
  return page.getByRole('button', {
    name: new RegExp(`^${escapeRegExp(title)}(\\s|$)`),
  });
}

test.beforeEach(async ({ page }) => {
  await seedSettings(page, 'settings-ai');
  await openApp(page, '/translate');
});

test('a backup brings the history back after the site data is cleared', async ({
  page,
}) => {
  test.setTimeout(180_000);
  const errors = collectPageErrors(page);

  // A translation in the history.
  await typeSource(page, TEXT);
  await expect
    .poll(() => copiedTranslation(page))
    .toBe(`[AI→French (Français)] ${TEXT}`);
  await page.reload();
  await openApp(page, '/history');
  await expect(entry(page, TEXT)).toBeVisible();

  // Back up: everything but the API keys, with a passphrase typed twice.
  await openApp(page, '/settings/backup');
  await expect(row(page, 'Back up now')).toHaveAccessibleName(
    /No backup yet/,
  );
  await row(page, 'Back up now').click();
  await expect(
    page.getByRole('checkbox', { name: /History and favorites/ }),
  ).toBeChecked();
  await expect(
    page.getByRole('switch', { name: /Include API keys and passwords/ }),
  ).not.toBeChecked();
  await fillField(page.getByLabel(/^Passphrase/), PASSPHRASE);
  await fillField(page.getByLabel(/^Repeat the passphrase/), PASSPHRASE);
  await expect(page.getByText('Passphrase strength: Strong')).toBeVisible();
  const download = page.waitForEvent('download', { timeout: CRYPTO_TIMEOUT });
  await page.getByRole('button', { name: 'Create backup' }).click();
  const backup = await download;
  expect(backup.suggestedFilename()).toMatch(
    /^mozhi-\d{4}-\d{2}-\d{2}\.mozhibackup$/,
  );
  const file = test.info().outputPath(backup.suggestedFilename());
  await backup.saveAs(file);
  const bytes = fs.readFileSync(file);
  expect(bytes.subarray(0, 8).toString('latin1')).toBe('MOZHIBAK');
  // Encrypted: neither the text nor the passphrase is in the file.
  expect(bytes.toString('latin1')).not.toContain(TEXT);
  expect(bytes.toString('latin1')).not.toContain('horse');
  await expect(dialog(page).getByText(/^Backup saved/)).toBeVisible({
    timeout: CRYPTO_TIMEOUT,
  });
  await page.getByRole('button', { name: 'Done' }).click();
  await expect(row(page, 'Back up now')).toHaveAccessibleName(
    /Last backup: /,
  );

  // Clear the site's data (what the browser's "Clear site data" does to
  // the app's storage): the history is gone.
  await page.evaluate(() => {
    localStorage.clear();
    sessionStorage.clear();
    // Keeps the settings fixture from being seeded again.
    sessionStorage.setItem('e2e.seeded', '1');
  });
  await page.reload();
  await openApp(page, '/history');
  await expect(page.getByRole('heading', { name: /^No history yet/ }))
    .toBeVisible();

  // Restore it from the file, through the browser's file chooser.
  await openApp(page, '/settings/backup');
  await row(page, 'Restore from a backup').click();
  const chooser = page.waitForEvent('filechooser');
  await page.getByRole('button', { name: 'Choose file' }).click();
  await (await chooser).setFiles(file);
  await expect(page.getByText(/^Made on .+ with Mozhi /)).toBeVisible();

  // A wrong passphrase is one clear error.
  await fillField(page.getByLabel(/^Passphrase/), 'not the passphrase');
  await page.getByRole('button', { name: 'Unlock' }).click();
  await expect(
    page.getByText('Wrong passphrase, or the file is damaged.'),
  ).toBeVisible({ timeout: CRYPTO_TIMEOUT });

  await fillField(page.getByLabel(/^Passphrase/), PASSPHRASE);
  await page.getByRole('button', { name: 'Unlock' }).click();
  await expect(page.getByText('Choose what to restore')).toBeVisible({
    timeout: CRYPTO_TIMEOUT,
  });
  await expect(
    page.getByRole('checkbox', { name: /History and favorites/ }),
  ).toHaveAccessibleName(/1 item/);
  await page.getByRole('button', { name: 'Replace my data' }).click();
  await expect(dialog(page).getByText(/^Backup restored/)).toBeVisible();
  await page.getByRole('button', { name: 'Done' }).click();

  // The history is back, and stays after a reload.
  await openApp(page, '/history');
  await expect(entry(page, TEXT)).toBeVisible();
  await page.reload();
  await openApp(page, '/history');
  await expect(entry(page, TEXT)).toBeVisible();
  expect(errors).toEqual([]);
});
