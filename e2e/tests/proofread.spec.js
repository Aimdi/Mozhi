// Proofreading with the (mock) AI provider: each suggested edit can be
// accepted or rejected on its card ("Reset" applies them all again), the
// corrected text is copied with its main button, and the writing
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
  await expect(
    page.getByRole('button', { name: 'Copy corrected text' }),
  ).toBeVisible();
}

/** The corrected text, copied with the result's main button. */
function corrected(page) {
  return copiedTranslation(page, page, 'Copy corrected text');
}

/**
 * The Accept or Reject button ([name]) of a suggested [edit] (its tooltip
 * is merged into the label while the pointer rests on it).
 */
function choice(edit, name) {
  return edit.getByRole('button', { name: new RegExp(`^${name}( ${name})?$`) });
}

/** Expects [edit]'s [name] button to be the selected one of the two. */
async function expectChosen(edit, name) {
  const other = name === 'Accept' ? 'Reject' : 'Accept';
  // Flutter web marks the selected button with aria-current.
  await expect(choice(edit, name)).toHaveAttribute('aria-current', 'true');
  await expect(choice(edit, other)).toHaveAttribute('aria-current', 'false');
}

test('suggested edits can be rejected and accepted one by one', async ({
  page,
}) => {
  const errors = collectPageErrors(page);
  await proofread(page);

  await expect(page.getByText('2 of 2 applied')).toBeVisible();
  const first = page.getByRole('group', { name: /^Grammar .*I has.*I have/ });
  const second = page.getByRole('group', {
    name: /^Grammar .*like to.*likes to Third person singular\.$/,
  });
  // Every suggestion is applied; each has its own Accept and Reject, and
  // there is no Accept all / Reject all.
  await expectChosen(first, 'Accept');
  await expectChosen(second, 'Accept');
  for (const name of ['Accept all', 'Reject all']) {
    await expect(page.getByRole('button', { name })).toHaveCount(0);
  }
  // "Reset" only once a suggestion is rejected.
  const reset = page.getByRole('button', { name: /^Reset/ });
  await expect(reset).toHaveCount(0);
  await expect.poll(() => corrected(page)).toBe(CORRECTED);

  // Reject one edit: only the other one stays in the corrected text.
  await choice(second, 'Reject').click();
  await expectChosen(second, 'Reject');
  await expectChosen(first, 'Accept');
  await expect(page.getByText('1 of 2 applied')).toBeVisible();
  await expect(reset).toBeVisible();
  await expect
    .poll(() => corrected(page))
    .toBe('I have a cat. It like to sleep.');

  // Reject the other one too: back to the original text.
  await choice(first, 'Reject').click();
  await expectChosen(first, 'Reject');
  await expect(page.getByText('0 of 2 applied')).toBeVisible();
  await expect.poll(() => corrected(page)).toBe(TEXT);

  // Accept one again: only that one is applied.
  await choice(second, 'Accept').click();
  await expectChosen(second, 'Accept');
  await expectChosen(first, 'Reject');
  await expect(page.getByText('1 of 2 applied')).toBeVisible();
  await expect
    .poll(() => corrected(page))
    .toBe('I has a cat. It likes to sleep.');

  // Reset: every edit again.
  await reset.click();
  await expect(page.getByText('2 of 2 applied')).toBeVisible();
  await expectChosen(first, 'Accept');
  await expectChosen(second, 'Accept');
  await expect(reset).toHaveCount(0);
  await expect.poll(() => corrected(page)).toBe(CORRECTED);
  expect(errors).toEqual([]);
});

test('the corrected text reads as one group with its actions', async ({
  page,
}) => {
  await proofread(page);

  // The result is a group named by its title, the hint that its
  // sentences can be rephrased and the model's summary; its actions are
  // buttons of their own inside it.
  const result = page.getByRole('group', { name: /^Corrected text / });
  await expect(result).toHaveAccessibleName(
    'Corrected text Tap a sentence for other ways to say it. ' +
      'Two grammar fixes; the tone is neutral.',
  );
  for (const name of [
    /^Hide changes/,
    /^Copy corrected text/,
    /^Share/,
    /^Use as input/,
  ]) {
    await expect(result.getByRole('button', { name })).toBeVisible();
  }
  expect(await corrected(page)).toBe(CORRECTED);
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
