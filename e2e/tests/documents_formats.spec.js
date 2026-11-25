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

test('a YAML file is translated with comments and keys preserved', async ({
  page,
}) => {
  const errors = collectPageErrors(page);
  const YAML = [
    '# App strings',
    'en:',
    `  greeting: "${TEXT}"`,
    '  count: 42',
    '',
  ].join('\n');

  const chooser = page.waitForEvent('filechooser');
  await page.getByRole('button', { name: 'Choose file' }).click();
  await (await chooser).setFiles({
    name: 'messages.yml',
    mimeType: 'application/yaml',
    buffer: Buffer.from(YAML, 'utf8'),
  });
  await expect(page.getByText('messages.yml', { exact: true })).toBeVisible();
  await expect(
    page.getByRole('checkbox', { name: 'YAML localization (.yml)' }),
  ).toBeVisible();
  await expect(page.getByRole('checkbox', { name: '1 segment' })).toBeVisible();

  await page.getByRole('button', { name: 'Translate', exact: true }).click();
  await expect(page.getByText('Translation complete')).toBeVisible();
  await expect(page.getByText('File name: messages.fr.yml')).toBeVisible();

  const download = page.waitForEvent('download');
  await page.getByRole('button', { name: 'Save file' }).click();
  const file = await download;
  expect(file.suggestedFilename()).toBe('messages.fr.yml');
  const path = test.info().outputPath(file.suggestedFilename());
  await file.saveAs(path);

  const yaml = fs.readFileSync(path, 'utf8');
  expect(yaml).toBe(YAML.replace(`"${TEXT}"`, `"${TRANSLATION}"`));
  expect(errors).toEqual([]);
});

test('a TMX translation memory inserts the target language <tuv>', async ({
  page,
}) => {
  const errors = collectPageErrors(page);
  const TMX = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<tmx version="1.4">',
    '  <header srclang="en"/>',
    '  <body>',
    '    <tu tuid="1">',
    `      <tuv xml:lang="en"><seg>${TEXT}</seg></tuv>`,
    '    </tu>',
    '  </body>',
    '</tmx>',
    '',
  ].join('\n');

  const chooser = page.waitForEvent('filechooser');
  await page.getByRole('button', { name: 'Choose file' }).click();
  await (await chooser).setFiles({
    name: 'memory.tmx',
    mimeType: 'application/xml',
    buffer: Buffer.from(TMX, 'utf8'),
  });
  await expect(page.getByText('memory.tmx', { exact: true })).toBeVisible();
  await expect(
    page.getByRole('checkbox', { name: 'TMX translation memory (.tmx)' }),
  ).toBeVisible();
  await expect(page.getByRole('checkbox', { name: '1 segment' })).toBeVisible();

  await page.getByRole('button', { name: 'Translate', exact: true }).click();
  await expect(page.getByText('Translation complete')).toBeVisible();
  await expect(page.getByText('File name: memory.fr.tmx')).toBeVisible();

  const download = page.waitForEvent('download');
  await page.getByRole('button', { name: 'Save file' }).click();
  const file = await download;
  expect(file.suggestedFilename()).toBe('memory.fr.tmx');
  const path = test.info().outputPath(file.suggestedFilename());
  await file.saveAs(path);

  const tmx = fs.readFileSync(path, 'utf8');
  expect(tmx).toContain(`<tuv xml:lang="en"><seg>${TEXT}</seg></tuv>`);
  expect(tmx).toContain(`<tuv xml:lang="fr"><seg>${TRANSLATION}</seg></tuv>`);
  expect(errors).toEqual([]);
});

test('a TOML file is translated with comments and tables preserved', async ({
  page,
}) => {
  const errors = collectPageErrors(page);
  const TOML = [
    '# App messages',
    '[messages]',
    `greeting = "${TEXT}"`,
    'retries = 3',
    '',
  ].join('\n');

  const chooser = page.waitForEvent('filechooser');
  await page.getByRole('button', { name: 'Choose file' }).click();
  await (await chooser).setFiles({
    name: 'settings.toml',
    mimeType: 'application/toml',
    buffer: Buffer.from(TOML, 'utf8'),
  });
  await expect(page.getByText('settings.toml', { exact: true })).toBeVisible();
  await expect(
    page.getByRole('checkbox', { name: 'TOML configuration (.toml)' }),
  ).toBeVisible();
  await expect(page.getByRole('checkbox', { name: '1 segment' })).toBeVisible();

  await page.getByRole('button', { name: 'Translate', exact: true }).click();
  await expect(page.getByText('Translation complete')).toBeVisible();
  await expect(page.getByText('File name: settings.fr.toml')).toBeVisible();

  const download = page.waitForEvent('download');
  await page.getByRole('button', { name: 'Save file' }).click();
  const file = await download;
  expect(file.suggestedFilename()).toBe('settings.fr.toml');
  const path = test.info().outputPath(file.suggestedFilename());
  await file.saveAs(path);

  const toml = fs.readFileSync(path, 'utf8');
  expect(toml).toBe(TOML.replace(`"${TEXT}"`, `"${TRANSLATION}"`));
  expect(errors).toEqual([]);
});

test('a Java .properties file is translated with keys preserved', async ({
  page,
}) => {
  const errors = collectPageErrors(page);
  const PROPS = ['# UI labels', `greeting = ${TEXT}`, ''].join('\n');

  const chooser = page.waitForEvent('filechooser');
  await page.getByRole('button', { name: 'Choose file' }).click();
  await (await chooser).setFiles({
    name: 'messages.properties',
    mimeType: 'text/plain',
    buffer: Buffer.from(PROPS, 'utf8'),
  });
  await expect(
    page.getByText('messages.properties', { exact: true }),
  ).toBeVisible();
  await expect(
    page.getByRole('checkbox', { name: 'Java properties (.properties)' }),
  ).toBeVisible();
  await expect(page.getByRole('checkbox', { name: '1 segment' })).toBeVisible();

  await page.getByRole('button', { name: 'Translate', exact: true }).click();
  await expect(page.getByText('Translation complete')).toBeVisible();
  await expect(
    page.getByText('File name: messages.fr.properties'),
  ).toBeVisible();

  const download = page.waitForEvent('download');
  await page.getByRole('button', { name: 'Save file' }).click();
  const file = await download;
  expect(file.suggestedFilename()).toBe('messages.fr.properties');
  const path = test.info().outputPath(file.suggestedFilename());
  await file.saveAs(path);

  const props = fs.readFileSync(path, 'utf8');
  expect(props).toBe(PROPS.replace(TEXT, TRANSLATION));
  expect(errors).toEqual([]);
});

/** Builds a valid single-page PDF 1.4 containing [line] in Helvetica. */
function buildMinimalPdf(line) {
  const stream = `BT /F1 12 Tf 72 720 Td (${line}) Tj ET`;
  const objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [5 0 R] /Count 1 /MediaBox [0 0 612 792] >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>',
    `<< /Length ${Buffer.byteLength(stream, 'latin1')} >>\nstream\n${stream}\nendstream`,
    '<< /Type /Page /Parent 2 0 R /Resources << /Font << /F1 3 0 R >> >> /Contents 4 0 R >>',
  ];
  const parts = [Buffer.from('%PDF-1.4\n%\xe2\xe3\xcf\xd3\n', 'latin1')];
  let offset = parts[0].length;
  const offsets = [0];
  for (let i = 0; i < objects.length; i++) {
    offsets.push(offset);
    const chunk = Buffer.from(`${i + 1} 0 obj\n${objects[i]}\nendobj\n`, 'latin1');
    parts.push(chunk);
    offset += chunk.length;
  }
  const xref = offset;
  let tail = `xref\n0 ${offsets.length}\n0000000000 65535 f \n`;
  for (let i = 1; i < offsets.length; i++) {
    tail += `${String(offsets[i]).padStart(10, '0')} 00000 n \n`;
  }
  tail += `trailer\n<< /Size ${offsets.length} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  parts.push(Buffer.from(tail, 'latin1'));
  return Buffer.concat(parts);
}

test('a PDF document is translated in the browser and saved as PDF', async ({
  page,
}) => {
  const errors = collectPageErrors(page);
  // PdfTextLayer.minCharacters requires at least 20 letters/digits so a real
  // text-layer page is distinguished from a scanned page with a page number.
  const pdfSentence = 'Thank you very much for testing Mozhi PDF translation.';
  const chooser = page.waitForEvent('filechooser');
  await page.getByRole('button', { name: 'Choose file' }).click();
  await (await chooser).setFiles({
    name: 'note.pdf',
    mimeType: 'application/pdf',
    buffer: buildMinimalPdf(pdfSentence),
  });
  await expect(page.getByText('note.pdf', { exact: true })).toBeVisible();
  await expect(
    page.getByRole('checkbox', { name: 'PDF document' }),
  ).toBeVisible();
  await expect(page.getByRole('checkbox', { name: '1 page' })).toBeVisible();
  await expect(page.getByText(pdfSentence)).toBeVisible();

  await page.getByRole('button', { name: 'Translate', exact: true }).click();
  await expect(page.getByText('Translation complete')).toBeVisible();
  await expect(page.getByText('File name: note.fr.pdf')).toBeVisible();

  const download = page.waitForEvent('download');
  await page.getByRole('button', { name: 'Save file' }).click();
  const file = await download;
  expect(file.suggestedFilename()).toBe('note.fr.pdf');
  const path = test.info().outputPath(file.suggestedFilename());
  await file.saveAs(path);

  const bytes = fs.readFileSync(path);
  expect(bytes.subarray(0, 5).toString('latin1')).toBe('%PDF-');
  expect(bytes.length).toBeGreaterThan(200);
  expect(errors).toEqual([]);
});
