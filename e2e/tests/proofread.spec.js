// Proofreading with the (mock) AI provider: the suggested edits can be
// applied and reverted one by one or all at once, and the writing
// statistics panel expands.
const { expect } = require('@playwright/test');
const {
  collectPageErrors,
  copiedTranslation,
  fillField,
  openApp,
  seedSettings,
  test,
} = require('./helpers');

const TEXT = 'I has a cat. It like to sleep.';
// The mock's answer: two grammar edits.
const CORRECTED = 'I have a cat. It likes to sleep.';

test.beforeEach(async ({ page }) => {
  await seedSettings(page, 'settings-ai');
  await openApp(page, '/proofread');
});

/** Enters [TEXT], presses Proofread and waits for the result. */
async function proofread(page) {
  const input = page.getByRole('textbox', { name: 'Text to proofread' });
  await fillField(input, TEXT);
  // The field keeps its name once it holds text (not the character count).
  await expect(input).toHaveAccessibleName(/^Text to proofread/);
  await page.getByRole('button', { name: 'Proofread', exact: true }).click();
  const result = page.getByRole('group', { name: /^Corrected text / });
  await expect(result).toBeVisible();
  return result;
}

test('suggested edits can be reverted and applied', async ({ page }) => {
  const errors = collectPageErrors(page);
  const result = await proofread(page);

  await expect(result).toHaveAccessibleName(
    'Corrected text Two grammar fixes; the tone is neutral.',
  );
  await expect(page.getByText('2 of 2 applied')).toBeVisible();
  const first = page.getByRole('checkbox', { name: /^Grammar .*I has.*I have/ });
  const second = page.getByRole('checkbox', {
    name: /^Grammar .*like to.*likes to Third person singular\.$/,
  });
  await expect(first).toBeChecked();
  await expect(second).toBeChecked();
  await expect(page.getByRole('button', { name: 'Accept all' })).toBeDisabled();
  await expect.poll(() => copiedTranslation(page, result)).toBe(CORRECTED);

  // Revert one edit: only the other one stays in the corrected text.
  await second.click();
  await expect(second).not.toBeChecked();
  await expect(first).toBeChecked();
  await expect(page.getByText('1 of 2 applied')).toBeVisible();
  await expect
    .poll(() => copiedTranslation(page, result))
    .toBe('I have a cat. It like to sleep.');

  // Reject all: back to the original text.
  await page.getByRole('button', { name: 'Reject all' }).click();
  await expect(page.getByText('0 of 2 applied')).toBeVisible();
  await expect(first).not.toBeChecked();
  await expect(page.getByRole('button', { name: 'Reject all' })).toBeDisabled();
  await expect.poll(() => copiedTranslation(page, result)).toBe(TEXT);

  // Accept all: every edit again.
  await page.getByRole('button', { name: 'Accept all' }).click();
  await expect(page.getByText('2 of 2 applied')).toBeVisible();
  await expect(first).toBeChecked();
  await expect(second).toBeChecked();
  await expect.poll(() => copiedTranslation(page, result)).toBe(CORRECTED);
  expect(errors).toEqual([]);
});

test('writing statistics panel expands', async ({ page }) => {
  await proofread(page);

  const stats = page.getByRole('button', { name: /^Writing statistics / });
  // 8 words; the reading time is derived from them.
  await expect(stats).toHaveAccessibleName(/^Writing statistics 8 words · /);
  await stats.click();

  // Expanded, the panel lists the statistics (of the corrected text,
  // with the original's where they differ).
  const panel = page.getByRole('group', { name: /^Writing statistics 8 words/ });
  await expect(panel).toBeVisible();
  for (const stat of [
    'Words 8',
    'Characters 30 originally, 32 after corrections',
    'Sentences 2',
    'Paragraphs 1',
    'Reading time',
    'Flesch reading ease',
  ]) {
    await expect(panel).toContainText(stat);
  }
});
