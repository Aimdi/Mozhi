const { test, expect } = require('@playwright/test');
const h = require('./helpers');
test('probe history', async ({ page }) => {
  await h.seedSettings(page, 'settings-ai');
  await h.openApp(page, '/translate');
  await h.typeSource(page, 'Good evening');
  await expect.poll(() => h.copiedTranslation(page)).toBe('[AI→French (Français)] Good evening');
  console.log(await page.locator('body').ariaSnapshot());
  await page.getByRole('tab', { name: 'History' }).click();
  await page.waitForTimeout(1500);
  console.log('=====HIST');
  console.log(await page.locator('body').ariaSnapshot());
  await page.getByRole('tab', { name: 'Settings' }).click();
  await page.waitForTimeout(1500);
  console.log('=====SET');
  console.log(await page.locator('body').ariaSnapshot());
});
