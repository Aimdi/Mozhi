// Localisation and web formats: an HTML page picked in Documents and a
// gettext catalogue pasted as text are translated with the mock AI
// provider; the results keep their markup, scripts and keys, translate only
// the text, and record the target language.
const fs = require('node:fs');
const { expect } = require('@playwright/test');
const {
  collectPageErrors,
  fillField,
  openApp,
  seedSettings,
  test,
} = require('./helpers');

// A phrase the mock really translates (see phrasebook.spec.js). Each file
// holds it as its only text, so it is sent on its own and comes back
// translated.
const TEXT = 'Thank you';
const TRANSLATION = 'merci';

const PAGE = [
  '<!DOCTYPE html>',
  '<html lang="en">',
  '<head><meta charset="utf-8"></head>',
  '<body>',
  '  <!-- greeting -->',
  `  <p class="hello"><b>${TEXT}</b></p>`,
  `  <script>console.log("${TEXT}");</script>`,
  '  <pre>  2024  </pre>',
  '</body>',
  '</html>',
  '',
].join('\n');

const CATALOGUE = [
  '# Mozhi end-to-end test',
  'msgid ""',
  'msgstr ""',
  '"Language: \\n"',
  '"Content-Type: text/plain; charset=UTF-8\\n"',
  '',
  '#: app.c:12',
  `msgid "${TEXT}"`,
  'msgstr ""',
  '',
].join('\n');

test.beforeEach(async ({ page }) => {
  await seedSettings(page, 'settings-ai');
  await openApp(page, '/documents');
});

test('an HTML page is translated with its markup and saved', async ({
  page,
}) => {
  const errors = collectPageErrors(page);
  await expect(
    page.getByRole('heading', { name: 'Translate documents' }).first(),
  ).toBeVisible();

  const chooser = page.waitForEvent('filechooser');
  await page.getByRole('button', { name: 'Choose file' }).click();
  await (await chooser).setFiles({
    name: 'welcome.html',
    mimeType: 'text/html',
    buffer: Buffer.from(PAGE, 'utf8'),
  });
  await expect(page.getByText('welcome.html', { exact: true })).toBeVisible();
  // Chips are exposed as checkboxes named by their label.
  await expect(page.getByRole('checkbox', { name: 'HTML page' })).toBeVisible();
  await expect(page.getByRole('checkbox', { name: '1 segment' })).toBeVisible();

  await page.getByRole('button', { name: 'Translate', exact: true }).click();
  await expect(page.getByText('Translation complete')).toBeVisible();
  await expect(page.getByText('File name: welcome.fr.html')).toBeVisible();

  const download = page.waitForEvent('download');
  await page.getByRole('button', { name: 'Save file' }).click();
  const file = await download;
  expect(file.suggestedFilename()).toBe('welcome.fr.html');
  const path = test.info().outputPath(file.suggestedFilename());
  await file.saveAs(path);
  await expect(page.getByText('File saved').first()).toBeVisible();

  const html = fs.readFileSync(path, 'utf8');
  // Only the visible text changed, and the page says it is French now.
  expect(html).toBe(
    PAGE.replace('<html lang="en">', '<html lang="fr">').replace(
      `<b>${TEXT}</b>`,
      `<b>${TRANSLATION}</b>`,
    ),
  );
  expect(html).toContain(`<script>console.log("${TEXT}");</script>`);
  expect(errors).toEqual([]);
});

test('a pasted gettext catalogue gets its msgstr and Language', async ({
  page,
}) => {
  const errors = collectPageErrors(page);
  await page.getByRole('button', { name: 'Text', exact: true }).click();
  const field = page.getByRole('textbox', { name: 'Text to translate' });
  await fillField(field, CATALOGUE);
  // The format is recognised from the pasted text.
  await expect(
    page.getByRole('checkbox', { name: 'Gettext catalogue (PO)' }),
  ).toBeVisible();
  await expect(page.getByRole('checkbox', { name: '1 segment' })).toBeVisible();

  await page.getByRole('button', { name: 'Translate', exact: true }).click();
  await expect(page.getByText('Translation complete')).toBeVisible();
  await expect(page.getByText('File name: translation.fr.po')).toBeVisible();

  const download = page.waitForEvent('download');
  await page.getByRole('button', { name: 'Save file' }).click();
  const file = await download;
  expect(file.suggestedFilename()).toBe('translation.fr.po');
  const path = test.info().outputPath(file.suggestedFilename());
  await file.saveAs(path);

  const po = fs.readFileSync(path, 'utf8');
  expect(po).toContain(`#: app.c:12\nmsgid "${TEXT}"\nmsgstr "${TRANSLATION}"\n`);
  expect(po).toContain('"Language: fr\\n"\n');
  expect(po).toContain('"Plural-Forms: nplurals=2; plural=(n > 1);\\n"\n');
  expect(po.startsWith('# Mozhi end-to-end test\nmsgid ""\n')).toBe(true);
  expect(errors).toEqual([]);
});
