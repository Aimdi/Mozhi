/*
 * Mozhi's app shell: keeps this web build's own files in the browser, so
 * that the app opens (and translates with the offline languages in the
 * browser's private storage) with no network once it has been opened.
 *
 * Copyright (c) 2026 Mozhi contributors. MIT License.
 *
 * tool/web_shell_manifest.py, run on the output of `flutter build web`,
 * writes mozhi_sw_manifest.json (every file of the build with its size and
 * SHA-256) and stamps SHELL_VERSION and SHELL_FILES below into the build's
 * copy of this file. Without them (a plain `flutter build web`) the install
 * fails at once and the app works online, as before.
 *
 * - Install: the manifest (whose version must be SHELL_VERSION: the files
 *   of this build), then every file not marked lazy, checked against its
 *   size and SHA-256, into the cache of this version. A file that an older
 *   version holds with the same SHA-256 is copied from it, not downloaded.
 *   Lazy files (the fonts of scripts a page may never show, the CanvasKit
 *   variant this browser does not load, renderer builds this build never
 *   loads) are kept when the page first loads them, or at the install when
 *   the browser's HTTP cache holds them (the page loaded them before this
 *   worker was there): the app then opens offline right after the install.
 * - Fetch: same-origin GET requests for the files of the manifest (and
 *   HEAD requests for them: the offline engine's worker asks whether its
 *   WebAssembly file is there), and navigations to the app (the scope
 *   itself or its index.html), are answered from the cache. Nothing else
 *   is touched: other servers (Mozhi
 *   instances, AI providers, model downloads), other methods, other paths
 *   (a model mirror next to the app, an API on the same server), and the
 *   offline language packs in the browser's private storage (OPFS) never
 *   pass through here.
 * - Update: a new build stamps a new SHELL_VERSION, so the browser installs
 *   its worker next to this one, which fills a new cache in the background;
 *   the page then shows "Update ready" and, when the user reloads, asks the
 *   new worker to take over ('mozhi-shell-activate'). Activating deletes
 *   the caches of the other versions of this scope.
 * - The page also asks the worker to keep the lazy files it loaded before
 *   the worker was there ('mozhi-shell-keep').
 *
 * The page registers it from Dart (lib/platform/app_shell_web.dart), with
 * the app's base URL as scope, and unregisters it (deleting its caches)
 * when "Keep the web app for offline use" is turned off. See
 * docs/self-hosting-mozhi.md for the cache headers it needs.
 */
'use strict';

// Stamped by tool/web_shell_manifest.py (each on one line).
const SHELL_VERSION = '';
const SHELL_FILES = [];

const MANIFEST = 'mozhi_sw_manifest.json';
const SCOPE = new URL(self.registration.scope);
// One app per scope: several apps on one origin keep separate caches.
const CACHE_PREFIX = `mozhi-shell:${SCOPE.pathname}:`;
const CACHE = CACHE_PREFIX + SHELL_VERSION;
const FILES = new Set(SHELL_FILES);
// Downloads at a time during the install.
const PARALLEL = 4;
// The most URLs one 'mozhi-shell-keep' message may name.
const MAX_KEEP = 2000;
const TYPES = {
  html: 'text/html',
  js: 'text/javascript',
  mjs: 'text/javascript',
  json: 'application/json',
  wasm: 'application/wasm',
};

self.addEventListener('install', (event) => {
  event.waitUntil(install());
});

self.addEventListener('activate', (event) => {
  event.waitUntil(removeOtherVersions());
});

self.addEventListener('message', (event) => {
  const message = event.data;
  if (!message || typeof message !== 'object') return;
  if (message.type === 'mozhi-shell-activate') {
    event.waitUntil(self.skipWaiting());
  } else if (message.type === 'mozhi-shell-keep' && Array.isArray(message.urls)) {
    event.waitUntil(keepLoaded(message.urls.slice(0, MAX_KEEP)));
  }
});

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (!SHELL_VERSION || (request.method !== 'GET' && request.method !== 'HEAD')) return;
  const target = new URL(request.url);
  if (target.origin !== SCOPE.origin || !target.pathname.startsWith(SCOPE.pathname)) return;
  let path = target.pathname.slice(SCOPE.pathname.length);
  if (request.mode === 'navigate') {
    // The app itself (any query or fragment): its links and the share
    // target open the scope.
    if (path !== '' && path !== 'index.html') return;
    path = 'index.html';
  } else if (!FILES.has(path)) {
    return;
  }
  event.respondWith(respond(event, path));
});

/* -------------------------------------------------------------------------- */
/* Install                                                                    */
/* -------------------------------------------------------------------------- */

async function install() {
  if (!SHELL_VERSION) {
    throw new Error('No manifest in this build (tool/web_shell_manifest.py)');
  }
  const response = await fetch(urlOf(MANIFEST), { cache: 'no-store' });
  if (!response.ok) throw new Error(`${MANIFEST}: HTTP ${response.status}`);
  const text = await response.text();
  const manifest = parseManifest(text);
  if (manifest.version !== SHELL_VERSION) {
    // The server has another build than this worker (an update half
    // deployed): the next check tries again.
    throw new Error(`${MANIFEST} is not the one of version ${SHELL_VERSION}`);
  }
  const cache = await caches.open(CACHE);
  const older = await olderFiles();
  const queue = [...manifest.files];
  async function next() {
    for (let entry = queue.shift(); entry; entry = queue.shift()) {
      const key = urlOf(entry.path);
      // Kept already: an install of this version that was interrupted.
      if (await cache.match(key)) continue;
      if (await copyFromOlder(entry, older, cache)) continue;
      if (!entry.lazy) await cache.put(key, await download(entry));
      else await keepIfCached(entry, cache);
    }
  }
  await Promise.all(Array.from({ length: PARALLEL }, next));
  // Last: a cache with its manifest is complete.
  await cache.put(
    urlOf(MANIFEST),
    new Response(text, { headers: { 'Content-Type': TYPES.json } }),
  );
}

/**
 * Keeps the lazy [entry] into [cache] when the browser's HTTP cache holds
 * it as the file of this build (checked); nothing is downloaded for it.
 */
async function keepIfCached(entry, cache) {
  try {
    const response = await fetch(urlOf(entry.path), {
      cache: 'only-if-cached',
      mode: 'same-origin',
    });
    if (!response.ok) return;
    const kept = await verified(entry, response);
    if (kept) await cache.put(urlOf(entry.path), kept);
  } catch (_) {
    // Not in the HTTP cache (or the browser cannot tell): kept when a
    // page loads it.
  }
}

/** The manifest's files, checked: relative paths, sizes, SHA-256. */
function parseManifest(text) {
  const manifest = JSON.parse(text);
  if (!manifest || manifest.schemaVersion !== 1 || !Array.isArray(manifest.files)) {
    throw new Error(`${MANIFEST}: not a manifest of schema 1`);
  }
  for (const entry of manifest.files) {
    const valid =
      entry &&
      typeof entry.path === 'string' &&
      /^[^/?#\\][^?#\\]*$/.test(entry.path) &&
      !entry.path.split('/').some((part) => part === '' || part === '.' || part === '..') &&
      Number.isSafeInteger(entry.size) &&
      entry.size >= 0 &&
      typeof entry.sha256 === 'string' &&
      /^[0-9a-f]{64}$/.test(entry.sha256);
    if (!valid) throw new Error(`${MANIFEST}: invalid entry ${JSON.stringify(entry)}`);
  }
  return manifest;
}

/** path -> [{cache, sha256}] of the complete caches of other versions. */
async function olderFiles() {
  const files = new Map();
  for (const name of await caches.keys()) {
    if (!name.startsWith(CACHE_PREFIX) || name === CACHE) continue;
    try {
      const cache = await caches.open(name);
      const stored = await cache.match(urlOf(MANIFEST));
      if (!stored) continue;
      for (const entry of parseManifest(await stored.text()).files) {
        const known = files.get(entry.path) || [];
        known.push({ cache, sha256: entry.sha256 });
        files.set(entry.path, known);
      }
    } catch (_) {
      // A damaged cache: its files are downloaded again.
    }
  }
  return files;
}

async function copyFromOlder(entry, older, cache) {
  for (const { cache: from, sha256 } of older.get(entry.path) || []) {
    if (sha256 !== entry.sha256) continue;
    const response = await from.match(urlOf(entry.path));
    if (!response) continue;
    await cache.put(urlOf(entry.path), response);
    return true;
  }
  return false;
}

/**
 * [entry] from the server, checked against its size and SHA-256: first
 * revalidated with the HTTP cache, then (a stale copy on the way) fetched
 * again past it.
 */
async function download(entry) {
  for (const mode of ['no-cache', 'reload']) {
    const response = await fetch(urlOf(entry.path), { cache: mode });
    if (!response.ok) throw new Error(`${entry.path}: HTTP ${response.status}`);
    const kept = await verified(entry, response);
    if (kept) return kept;
  }
  throw new Error(`${entry.path}: not the file of this build (size or SHA-256)`);
}

/* -------------------------------------------------------------------------- */
/* Fetch                                                                      */
/* -------------------------------------------------------------------------- */

async function respond(event, path) {
  const head = event.request.method === 'HEAD';
  const cached = await caches.match(urlOf(path), { cacheName: CACHE });
  if (cached) {
    if (!head) return cached;
    return new Response(null, {
      status: cached.status,
      statusText: cached.statusText,
      headers: cached.headers,
    });
  }
  // Not kept (yet): a lazy file, or storage the browser cleared.
  const response = await fetch(event.request);
  if (!head && response.ok && response.type === 'basic') {
    event.waitUntil(keep(path, response.clone()).catch(() => {}));
  }
  return response;
}

/** Keeps the lazy files of the manifest among [urls] (those the page loaded). */
async function keepLoaded(urls) {
  const paths = new Set();
  for (const value of urls) {
    try {
      const target = new URL(String(value), SCOPE);
      if (target.origin !== SCOPE.origin || !target.pathname.startsWith(SCOPE.pathname)) continue;
      const path = target.pathname.slice(SCOPE.pathname.length);
      if (FILES.has(path)) paths.add(path);
    } catch (_) {
      // Not a URL.
    }
  }
  for (const path of paths) {
    try {
      if (await caches.match(urlOf(path), { cacheName: CACHE })) continue;
      // Most come from the browser's HTTP cache.
      const response = await fetch(urlOf(path), { cache: 'force-cache' });
      if (response.ok) await keep(path, response);
    } catch (_) {
      // Kept the next time the page loads it.
    }
  }
}

/**
 * Stores [response] for [path] when it is the file of this version (the
 * server may have a newer build than this worker), into this version's
 * cache if it still exists (not after the app shell was turned off).
 */
async function keep(path, response) {
  const entry = (await manifestEntries()).get(path);
  if (!entry) return;
  const kept = await verified(entry, response);
  if (!kept || !(await caches.has(CACHE))) return;
  await (await caches.open(CACHE)).put(urlOf(path), kept);
}

let entriesPromise = null;

/** path -> entry of this version's stored manifest. */
function manifestEntries() {
  if (!entriesPromise) {
    entriesPromise = (async () => {
      const stored = await caches.match(urlOf(MANIFEST), { cacheName: CACHE });
      if (!stored) throw new Error('No manifest kept');
      return new Map(parseManifest(await stored.text()).files.map((entry) => [entry.path, entry]));
    })();
    entriesPromise.catch(() => {
      entriesPromise = null;
    });
  }
  return entriesPromise;
}

/* -------------------------------------------------------------------------- */
/* Activate                                                                   */
/* -------------------------------------------------------------------------- */

async function removeOtherVersions() {
  for (const name of await caches.keys()) {
    if (name.startsWith(CACHE_PREFIX) && name !== CACHE) await caches.delete(name);
  }
}

/* -------------------------------------------------------------------------- */
/* Helpers                                                                    */
/* -------------------------------------------------------------------------- */

function urlOf(path) {
  return new URL(path, SCOPE).href;
}

/**
 * The server's security headers, kept with every file so a page served
 * from the cache is as protected as one from the network (a
 * `frame-ancestors` CSP or X-Frame-Options against clickjacking, a
 * stricter CSP, the worker's own CSP; docs/self-hosting-mozhi.md).
 */
const SECURITY_HEADERS = [
  'Content-Security-Policy',
  'Content-Security-Policy-Report-Only',
  'X-Frame-Options',
  'X-Content-Type-Options',
  'Referrer-Policy',
  'Permissions-Policy',
  'Cross-Origin-Opener-Policy',
  'Cross-Origin-Embedder-Policy',
  'Cross-Origin-Resource-Policy',
];

/**
 * A response to keep for [entry] made of [response]'s bytes when they are
 * the entry's (size and SHA-256), else null. Only the content type and
 * the server's security headers ([SECURITY_HEADERS]) are kept: the body
 * is decoded already (no Content-Encoding), and a redirect the server
 * made is not repeated.
 */
async function verified(entry, response) {
  const bytes = new Uint8Array(await response.arrayBuffer());
  // index.html is hashed with its <base href> emptied: it may be edited to
  // serve the app from a sub-path (docs/getting-started.md).
  const checked = entry.base ? withoutBaseHref(bytes) : bytes;
  if (checked.length !== entry.size || (await sha256(checked)) !== entry.sha256) return null;
  const headers = new Headers();
  const extension = entry.path.split('.').pop();
  headers.set('Content-Type', response.headers.get('Content-Type') || TYPES[extension] || 'application/octet-stream');
  for (const name of SECURITY_HEADERS) {
    const value = response.headers.get(name);
    if (value !== null) headers.set(name, value);
  }
  return new Response(bytes, { status: 200, statusText: 'OK', headers });
}

/** [bytes] (UTF-8 HTML) with the value of the first <base href> emptied. */
function withoutBaseHref(bytes) {
  // The BOM (if any) is kept, like Python's decoding in the tool.
  const text = new TextDecoder('utf-8', { ignoreBOM: true }).decode(bytes);
  return new TextEncoder().encode(text.replace(/<base\s+href="[^"]*"/i, '<base href=""'));
}

async function sha256(bytes) {
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('');
}
