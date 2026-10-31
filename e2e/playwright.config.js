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
//   E2E_SERVICE_WORKERS  `allow` runs every spec with the app shell's
//                 service worker (web/mozhi_sw.js) registered; by default
//                 only offline_shell.spec.js allows it: each test starts a
//                 fresh browser profile, where the worker would download
//                 the whole build again (about 30 MB) next to the test.
//
// Browsers: the `chromium` project runs every spec; `firefox` and `webkit`
// (Gecko and the engine of Safari) run the core specs (CORE_SPECS), so CI
// shows that the app works in every engine a user may open it with. Pick
// one with `--project` (CI runs one job per browser; `npx playwright
// install --with-deps firefox webkit` installs the other two).
const path = require('node:path');
const { defineConfig, devices } = require('@playwright/test');

const webDir = path.resolve(
  __dirname,
  process.env.E2E_WEB_DIR || path.join('..', 'build', 'web'),
);
const appPort = Number(process.env.E2E_APP_PORT || 8080);
const mockPort = Number(process.env.E2E_MOCK_PORT || 8787);
const isCI = !!process.env.CI;

/**
 * The specs that every browser runs: start-up and the routes, translating,
 * settings, history, the on-device engine, documents and the offline app
 * shell. The rest run in Chromium only.
 */
const CORE_SPECS = [
  'app',
  'translate',
  'settings',
  'history',
  'offline_engine',
  'documents_formats',
  'offline_shell',
].map((name) => `${name}.spec.js`);

const viewport = { width: 412, height: 915 };

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
    viewport,
    serviceWorkers:
      process.env.E2E_SERVICE_WORKERS === 'allow' ? 'allow' : 'block',
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
    actionTimeout: 15_000,
    navigationTimeout: 60_000,
  },
  // The specs read the translation through the Copy button, so each
  // browser gets the clipboard the way it allows it (helpers.js reads it
  // back, see readClipboard).
  projects: [
    {
      name: 'chromium',
      use: {
        ...devices['Desktop Chrome'],
        viewport,
        permissions: ['clipboard-read', 'clipboard-write'],
      },
    },
    {
      name: 'firefox',
      testMatch: CORE_SPECS,
      // CanvasKit without a GPU is slower in Gecko.
      timeout: 150_000,
      use: {
        ...devices['Desktop Firefox'],
        viewport,
        // Firefox has no clipboard permissions: these prefs let a page
        // read the clipboard without the paste prompt (as in Playwright's
        // own tests).
        launchOptions: {
          firefoxUserPrefs: {
            'dom.events.asyncClipboard.readText': true,
            'dom.events.testing.asyncClipboard': true,
          },
        },
      },
    },
    {
      name: 'webkit',
      testMatch: CORE_SPECS,
      timeout: 150_000,
      use: {
        ...devices['Desktop Safari'],
        viewport,
        // Like the other two (Desktop Safari is a 2x screen: four times
        // the pixels for CanvasKit to draw on a CI runner).
        deviceScaleFactor: 1,
        // WebKit knows only clipboard-read; writing needs the click on
        // Copy (a user gesture), which the specs make.
        permissions: ['clipboard-read'],
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
