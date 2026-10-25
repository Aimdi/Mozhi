// Office documents: a Word file is picked in Documents, translated with the
// mock AI provider, and saved as a Word file again (a download in the web
// app) whose text is translated while its formatting, other parts and
// layout stay.
const fs = require('node:fs');
const zlib = require('node:zlib');
const { expect } = require('@playwright/test');
const { collectPageErrors, openApp, seedSettings, test } = require('./helpers');

// A phrase the mock really translates (see phrasebook.spec.js).
const TEXT = 'Thank you';
const TRANSLATION = 'merci';
const DOCX_TYPE =
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document';

// --- A minimal ZIP writer and reader (stored / deflated entries). ---------

const CRC_TABLE = Array.from({ length: 256 }, (_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});

function crc32(buffer) {
  let crc = 0xffffffff;
  for (const byte of buffer) crc = CRC_TABLE[(crc ^ byte) & 0xff] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

/** A ZIP package of [files] (name -> string), every entry stored. */
function zip(files) {
  const locals = [];
  const centrals = [];
  let offset = 0;
  for (const [name, content] of Object.entries(files)) {
    const data = Buffer.from(content, 'utf8');
    const nameBytes = Buffer.from(name, 'utf8');
    const crc = crc32(data);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(0x0800, 6); // UTF-8 names
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(data.length, 18);
    local.writeUInt32LE(data.length, 22);
    local.writeUInt16LE(nameBytes.length, 26);
    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(20, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(0x0800, 8);
    central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(data.length, 20);
    central.writeUInt32LE(data.length, 24);
    central.writeUInt16LE(nameBytes.length, 28);
    central.writeUInt32LE(offset, 42);
    locals.push(local, nameBytes, data);
    centrals.push(central, nameBytes);
    offset += local.length + nameBytes.length + data.length;
  }
  const directory = Buffer.concat(centrals);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(Object.keys(files).length, 8);
  end.writeUInt16LE(Object.keys(files).length, 10);
  end.writeUInt32LE(directory.length, 12);
  end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, directory, end]);
}

/** The entries of a ZIP package: name -> Buffer, in order. */
function unzip(buffer) {
  let end = buffer.length - 22;
  while (end >= 0 && buffer.readUInt32LE(end) !== 0x06054b50) end--;
  const count = buffer.readUInt16LE(end + 10);
  let position = buffer.readUInt32LE(end + 16);
  const entries = new Map();
  for (let i = 0; i < count; i++) {
    const method = buffer.readUInt16LE(position + 10);
    const size = buffer.readUInt32LE(position + 20);
    const nameLength = buffer.readUInt16LE(position + 28);
    const extraLength = buffer.readUInt16LE(position + 30);
    const commentLength = buffer.readUInt16LE(position + 32);
    const local = buffer.readUInt32LE(position + 42);
    const name = buffer.toString(
      'utf8',
      position + 46,
      position + 46 + nameLength,
    );
    const start =
      local +
      30 +
      buffer.readUInt16LE(local + 26) +
      buffer.readUInt16LE(local + 28);
    const raw = buffer.subarray(start, start + size);
    entries.set(name, method === 8 ? zlib.inflateRawSync(raw) : raw);
    position += 46 + nameLength + extraLength + commentLength;
  }
  return entries;
}

// --- The document. ---------------------------------------------------------

const W = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
const DECLARATION =
  '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n';
const STYLES =
  `${DECLARATION}<w:styles xmlns:w="${W}"><w:docDefaults><w:rPrDefault>` +
  '<w:rPr><w:lang w:val="en-US"/></w:rPr></w:rPrDefault></w:docDefaults>' +
  '</w:styles>';

function thankYouDocx() {
  const office = 'application/vnd.openxmlformats-officedocument';
  return zip({
    '[Content_Types].xml':
      `${DECLARATION}<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">` +
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
      '<Default Extension="xml" ContentType="application/xml"/>' +
      `<Override PartName="/word/document.xml" ContentType="${office}.wordprocessingml.document.main+xml"/>` +
      `<Override PartName="/word/styles.xml" ContentType="${office}.wordprocessingml.styles+xml"/>` +
      '</Types>',
    '_rels/.rels':
      `${DECLARATION}<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">` +
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>' +
      '</Relationships>',
    'word/document.xml':
      `${DECLARATION}<w:document xmlns:w="${W}"><w:body>` +
      '<w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:rPr><w:b/>' +
      `<w:lang w:val="en-US"/></w:rPr><w:t>${TEXT}</w:t></w:r></w:p>` +
      '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>2024</w:t></w:r></w:p></w:tc>' +
      '</w:tr></w:tbl><w:sectPr/></w:body></w:document>',
    'word/styles.xml': STYLES,
  });
}

test.beforeEach(async ({ page }) => {
  await seedSettings(page, 'settings-ai');
  await openApp(page, '/documents');
});

test('a Word document is translated and saved as a Word document', async ({
  page,
}) => {
  const errors = collectPageErrors(page);
  await expect(
    page.getByRole('heading', { name: 'Translate documents' }).first(),
  ).toBeVisible();

  const chooser = page.waitForEvent('filechooser');
  await page.getByRole('button', { name: 'Choose file' }).click();
  await (await chooser).setFiles({
    name: 'thanks.docx',
    mimeType: DOCX_TYPE,
    buffer: thankYouDocx(),
  });
  await expect(page.getByText('thanks.docx', { exact: true })).toBeVisible();
  await expect(page.getByText('Word document (DOCX)')).toBeVisible();
  await expect(page.getByText('1 segment', { exact: true })).toBeVisible();
  await expect(
    page.getByText('The preview shows the text only.', { exact: false }),
  ).toBeVisible();

  await page.getByRole('button', { name: 'Translate', exact: true }).click();
  await expect(page.getByText('Translation complete')).toBeVisible();
  await expect(page.getByText('File name: thanks.fr.docx')).toBeVisible();

  const download = page.waitForEvent('download');
  await page.getByRole('button', { name: 'Save file' }).click();
  const file = await download;
  expect(file.suggestedFilename()).toBe('thanks.fr.docx');
  const path = test.info().outputPath(file.suggestedFilename());
  await file.saveAs(path);
  // The snack bar, and its announcement for screen readers.
  await expect(page.getByText('File saved').first()).toBeVisible();

  const entries = unzip(fs.readFileSync(path));
  expect([...entries.keys()]).toEqual([
    '[Content_Types].xml',
    '_rels/.rels',
    'word/document.xml',
    'word/styles.xml',
  ]);
  const xml = entries.get('word/document.xml').toString('utf8');
  // The translated run keeps its formatting and gets the target language.
  expect(xml).toContain(
    '<w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:rPr><w:b/>' +
      '<w:lang w:val="fr-FR"/></w:rPr>' +
      `<w:t xml:space="preserve">${TRANSLATION}</w:t></w:r></w:p>`,
  );
  // Numbers and the table stay as they were.
  expect(xml).toContain('<w:tc><w:p><w:r><w:t>2024</w:t></w:r></w:p></w:tc>');
  expect(xml).not.toContain(TEXT);
  expect(entries.get('word/styles.xml').toString('utf8')).toContain(
    '<w:lang w:val="fr-FR"/>',
  );
  expect(errors).toEqual([]);
});

test('a damaged office file is explained, not opened', async ({ page }) => {
  const chooser = page.waitForEvent('filechooser');
  await page.getByRole('button', { name: 'Choose file' }).click();
  await (await chooser).setFiles({
    name: 'broken.docx',
    mimeType: DOCX_TYPE,
    buffer: Buffer.from('not a zip file'),
  });
  await expect(
    page.getByText(
      "This file is damaged, or it isn't really a Word document (DOCX).",
    ),
  ).toBeVisible();
});
