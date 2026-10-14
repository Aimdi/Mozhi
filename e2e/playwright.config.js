// @ts-check
// Playwright configuration for the Mozhi web E2E suite.
//
// The suite runs against a release web build (default: ../build/web, or
// $E2E_WEB_DIR) served by `python3 -m http.server`, plus e2e/mock_server.py
// standing in for a Mozhi instance and an OpenAI-compatible provider. Both
// servers are started by Playwright (`webServer`) unless they already run
// (reuseExistingServer outside CI).
//
// Environment:
//   E2E_WEB_DIR   web build to serve (default ../build/web)
//   E2E_APP_PORT  port for the web build (default 8080)
//   E2E_MOCK_PORT port for the mock server (default 8787; the settings
//                 fixtures are rewritten to it)
const path = require('node:path');
const { defineConfig, devices } = require('@playwright/test');

const webDir = path.resolve(
  __dirname,
  process.env.E2E_WEB_DIR || path.join('..', 'build', 'web'),
);
const appPort = Number(process.env.E2E_APP_PORT || 8080);
const mockPort = Number(process.env.E2E_MOCK_PORT || 8787);
const isCI = !!process.env.CI;

module.exports = defineConfig({
  testDir: './tests',
  // Flutter web (CanvasKit) is CPU heavy: one page at a time keeps the
  // timings stable on CI runners.
  workers: 1,
  fullyParallel: false,
  forbidOnly: isCI,
  retries: isCI ? 1 : 0,
  timeout: 90_000,
  expect: { timeout: 20_000 },
  reporter: isCI
    ? [['list'], ['html', { open: 'never' }], ['github']]
    : [['list'], ['html', { open: 'never' }]],
  use: {
    baseURL: `http://127.0.0.1:${appPort}`,
    locale: 'en-US',
    viewport: { width: 412, height: 915 },
    // The specs read the translation through the Copy button.
    permissions: ['clipboard-read', 'clipboard-write'],
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
    actionTimeout: 15_000,
    navigationTimeout: 60_000,
  },
  projects: [
    {
      name: 'chromium',
      use: {
        ...devices['Desktop Chrome'],
        viewport: { width: 412, height: 915 },
      },
    },
  ],
  webServer: [
    {
      command: `python3 mock_server.py ${mockPort}`,
      cwd: __dirname,
      url: `http://127.0.0.1:${mockPort}/__health`,
      reuseExistingServer: !isCI,
      timeout: 30_000,
    },
    {
      command: `python3 -m http.server ${appPort} --bind 127.0.0.1 --directory "${webDir}"`,
      url: `http://127.0.0.1:${appPort}/`,
      reuseExistingServer: !isCI,
      // http.server logs every request to stderr.
      stderr: 'ignore',
      timeout: 30_000,
    },
  ],
});
