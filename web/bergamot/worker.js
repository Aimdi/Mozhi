/*
 * Mozhi's on-device translation worker: Mozilla's Firefox Translations
 * (Bergamot) engine and CLD2, compiled to WebAssembly by
 * packages/bergamot_translator/tool/build_wasm.sh, and the offline language
 * packs in the browser's Origin Private File System (OPFS).
 *
 * Copyright (c) 2026 Mozhi contributors. MIT License.
 *
 * The app talks to it from Dart (packages/bergamot_translator/lib/src/
 * engine/web/). Protocol (docs/offline-engine.md, "Web"):
 *
 *   page -> worker  {id, op, ...arguments}
 *   worker -> page  {id, ok: true, result} | {id, ok: false, error}
 *   error           {kind, message}: kind is "engine" (the WASM engine
 *                   failed; it is restarted for the next request),
 *                   "storage" (OPFS: quota, a private window, ...),
 *                   "checksum" (a download did not match the catalog),
 *                   "missing" (a file is not there), "unsupported" (the
 *                   browser lacks a feature) or "protocol" (a bad request).
 *
 * Requests run one at a time, in the order they arrive (a translation is a
 * synchronous WASM call; it cannot be interrupted). The app keeps its own
 * queue and sends one translation at a time, so an aborted request that
 * still waits there never reaches the worker.
 *
 * Nothing here uses the network except fetching bergamot-translator.wasm
 * from this origin: model files arrive from the app (which downloads them
 * through its own HTTP client, with its network rules) and are stored,
 * verified and read here.
 */
'use strict';

const ENGINE_SCRIPT = 'bergamot-translator.js';
const ENGINE_WASM = 'bergamot-translator.wasm';
const ABI_VERSION = 2;

// mozhi_bergamot.h
const TRANSLATE_HTML = 1;
const TRANSLATE_ALIGNMENT = 2;
const TRANSLATE_QUALITY = 4;
const DETECT_BEST_EFFORT = 1;
const DETECTION_SIZE = 96;

// What each catalog file kind needs (Bergamot's alignment rules).
const ALIGNMENT = {
  model: 256,
  lexicalShortlist: 64,
  vocab: 64,
  srcVocab: 64,
  trgVocab: 64,
};

// The OPFS folder of this worker; models go to models/<pair>/<version>/,
// downloads in progress to .downloads/<pair>/<version>/<file>.gz.part.
const ROOT_FOLDER = 'bergamot';
const MANIFEST = 'manifest.json';

let maxModels = 2;
// Seconds without a request after which the engine is dropped: WebAssembly
// memory never shrinks (a pivot with two models peaks around 350 MB), so
// an idle tab gives it all back; the next request starts the engine again
// (~0.1 s with the compiled module kept, plus ~0.5 s per model).
let idleSeconds = 300;
let idleTimer = null;

/* -------------------------------------------------------------------------- */
/* Messages                                                                   */
/* -------------------------------------------------------------------------- */

let queue = Promise.resolve();

self.onmessage = (event) => {
  const message = event.data;
  if (idleTimer !== null) {
    clearTimeout(idleTimer);
    idleTimer = null;
  }
  queue = queue.then(() => handle(message)).then(scheduleIdleReset);
};

function scheduleIdleReset() {
  if (idleTimer !== null) clearTimeout(idleTimer);
  idleTimer = instance && idleSeconds > 0
    ? setTimeout(() => {
        idleTimer = null;
        reset();
      }, idleSeconds * 1000)
    : null;
}

async function handle(message) {
  const id = message && message.id;
  try {
    const operation = OPERATIONS[message && message.op];
    if (!operation) throw failure('protocol', `Unknown op ${message && message.op}`);
    const result = await operation(message);
    self.postMessage({ id, ok: true, result: result === undefined ? null : result });
  } catch (error) {
    self.postMessage({ id, ok: false, error: describe(error) });
  }
}

function failure(kind, message) {
  const error = new Error(message);
  error.kind = kind;
  return error;
}

function describe(error) {
  if (error && typeof error.kind === 'string') {
    return { kind: error.kind, message: String(error.message) };
  }
  if (error instanceof DOMException) {
    // QuotaExceededError, NotAllowedError (private windows), ...
    const kind = error.name === 'NotFoundError' ? 'missing' : 'storage';
    return { kind, message: `${error.name}: ${error.message}` };
  }
  return { kind: 'engine', message: String((error && error.message) || error) };
}

const OPERATIONS = {
  probe,
  configure,
  init: async () => (await engine()).info,
  translate,
  identify,
  preload: async ({ chain }) => {
    await modelsFor(chain);
  },
  release: async ({ key }) => {
    unload(key);
  },
  trim: async () => {
    for (const key of [...loaded.keys()]) {
      if (!lastChain.includes(key)) unload(key);
    }
  },
  dispose: async () => {
    reset();
  },
  list,
  usage,
  downloadOpen,
  downloadWrite,
  downloadClose,
  fingerprint,
  install,
  commit,
  remove,
  cleanUp,
};

/* -------------------------------------------------------------------------- */
/* Capabilities                                                               */
/* -------------------------------------------------------------------------- */

// A module with one v128 instruction: valid only with WASM SIMD.
const SIMD_TEST = new Uint8Array([
  0, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 96, 0, 1, 123, 3, 2, 1, 0, 10, 10, 1,
  8, 0, 65, 0, 253, 15, 253, 98, 11,
]);

/** What this browser has of what the engine needs. */
async function probe() {
  const result = {
    simd: false,
    opfs: false,
    syncAccess: false,
    decompression: typeof DecompressionStream === 'function',
    digest: !!(self.crypto && self.crypto.subtle),
    segmenter: typeof Intl === 'object' && typeof Intl.Segmenter === 'function',
    engine: false,
    secure: self.isSecureContext !== false,
    persisted: false,
  };
  try {
    result.simd = WebAssembly.validate(SIMD_TEST);
  } catch (_) {}
  try {
    await root();
    result.opfs = true;
    result.syncAccess =
      typeof FileSystemFileHandle === 'function' &&
      'createSyncAccessHandle' in FileSystemFileHandle.prototype;
  } catch (_) {}
  try {
    result.persisted = !!(await navigator.storage.persisted());
  } catch (_) {}
  try {
    const response = await fetch(ENGINE_WASM, { method: 'HEAD', cache: 'no-cache' });
    result.engine = response.ok || response.status === 405;
  } catch (_) {}
  return result;
}

async function configure(message) {
  if (Number.isInteger(message.maxModels) && message.maxModels >= 2) {
    maxModels = message.maxModels;
  }
  if (Number.isInteger(message.idleSeconds) && message.idleSeconds >= 0) {
    idleSeconds = message.idleSeconds;
  }
  while (loaded.size > maxModels) evictOldest();
}

/* -------------------------------------------------------------------------- */
/* The engine                                                                 */
/* -------------------------------------------------------------------------- */

let compiled = null; // Promise<WebAssembly.Module>, kept across restarts
let instance = null; // Promise<{module, api, info}>
let running = null; // the resolved instance

/** The running engine, started on first use (and again after a failure). */
function engine() {
  if (!instance) {
    const starting = start();
    instance = starting;
    starting.then(
      (started) => {
        if (instance === starting) running = started;
      },
      () => {
        if (instance === starting) instance = null;
      },
    );
  }
  return instance;
}

async function start() {
  if (typeof loadBergamot !== 'function') {
    try {
      importScripts(ENGINE_SCRIPT);
    } catch (error) {
      throw failure('unsupported', `Cannot load ${ENGINE_SCRIPT}: ${error.message}`);
    }
  }
  if (!compiled) {
    compiled = (async () => {
      const response = await fetch(ENGINE_WASM, { credentials: 'same-origin' });
      if (!response.ok) throw new Error(`HTTP ${response.status} for ${ENGINE_WASM}`);
      if (WebAssembly.compileStreaming &&
          (response.headers.get('Content-Type') || '').startsWith('application/wasm')) {
        return WebAssembly.compileStreaming(response);
      }
      return WebAssembly.compile(await response.arrayBuffer());
    })();
    compiled.catch(() => {
      compiled = null;
    });
  }
  let wasm;
  try {
    wasm = await compiled;
  } catch (error) {
    throw failure('unsupported', `Cannot load ${ENGINE_WASM}: ${error.message}`);
  }
  const module = await new Promise((resolve, reject) => {
    const config = {
      print: () => {},
      printErr: () => {},
      onAbort: (what) => reject(failure('engine', `Engine aborted: ${what}`)),
      instantiateWasm(imports, receive) {
        WebAssembly.instantiate(wasm, imports).then(
          (created) => receive(created, wasm),
          (error) => reject(failure('engine', `Cannot start the engine: ${error.message}`)),
        );
        return {};
      },
      onRuntimeInitialized() {
        resolve(config);
      },
    };
    loadBergamot(config);
  });
  const api = module.asm;
  const abi = api.mozhi_bergamot_abi_version();
  if (abi !== ABI_VERSION) {
    throw failure('unsupported', `Engine ABI ${abi}, expected ${ABI_VERSION}`);
  }
  const info = {
    abi,
    version: module.mozhi.utf8ToString(api.mozhi_bergamot_version()),
    gemm: typeof WebAssembly.mozIntGemm === 'function' ? 'mozIntGemm' : 'fallback',
  };
  return { module, api, info };
}

/**
 * Forgets the engine and its models: the WASM instance (and its memory) is
 * dropped, a new one starts with the next request.
 */
function reset() {
  loaded.clear();
  lastChain = [];
  instance = null;
  running = null;
}

/**
 * Runs `body(engine)`. An exception from inside the WASM module may leave
 * it in any state (C++ exceptions are not caught in this build, and an
 * abort is final), so the engine is dropped and restarts with the next
 * request.
 */
async function guarded(body) {
  const started = await engine();
  try {
    return body(started);
  } catch (error) {
    reset();
    if (error && error.kind) throw error;
    throw failure('engine', `The engine failed: ${(error && error.message) || error}`);
  }
}

function allocString(running, text) {
  const { api, module } = running;
  const size = module.mozhi.lengthBytesUTF8(text) + 1;
  const pointer = api.malloc(size);
  if (!pointer) throw failure('engine', 'Out of memory');
  module.mozhi.stringToUTF8(text, pointer, size);
  return pointer;
}

function lastError(running) {
  const pointer = running.api.mozhi_bergamot_last_error();
  return pointer ? running.module.mozhi.utf8ToString(pointer) : 'unknown engine error';
}

/* --- Models ---------------------------------------------------------------- */

// key -> model handle, least recently used first.
const loaded = new Map();
let lastChain = [];

function unload(key) {
  const handle = loaded.get(key);
  if (handle === undefined) return;
  loaded.delete(key);
  if (!running) return;
  try {
    running.api.mozhi_bergamot_model_destroy(handle);
  } catch (_) {
    reset();
  }
}

/** Unloads the least recently used model that `keep` does not list. */
function evictOne(keep) {
  for (const key of loaded.keys()) {
    if (!keep.includes(key)) {
      unload(key);
      return true;
    }
  }
  return false;
}

function evictOldest() {
  if (!evictOne(lastChain)) unload(loaded.keys().next().value);
}

/** Valid BCP-47 for Intl.Segmenter (zh_hant -> zh-Hant), else "und". */
function locale(code) {
  try {
    return Intl.getCanonicalLocales(String(code).replace(/_/g, '-'))[0] || 'und';
  } catch (_) {
    return 'und';
  }
}

/**
 * The loaded models of `chain` (loading those that are not), in order.
 * Least recently used models are unloaded first, before loading, so that
 * at most `maxModels` are in memory.
 */
async function modelsFor(chain) {
  if (!Array.isArray(chain) || chain.length < 1 || chain.length > 2) {
    throw failure('protocol', 'A chain has one or two models');
  }
  const keys = chain.map((model) => model.key);
  lastChain = keys;
  const handles = [];
  for (const spec of chain) {
    let handle = loaded.get(spec.key);
    if (handle === undefined) {
      while (loaded.size >= maxModels && evictOne(keys)) {}
      handle = await loadModel(spec);
      lastChain = keys;
    } else {
      loaded.delete(spec.key);
    }
    loaded.set(spec.key, handle);
    handles.push(handle);
  }
  return handles;
}

async function loadModel(spec) {
  const files = [
    ['model', spec.model],
    ['lexicalShortlist', spec.shortlist],
    ['vocab', spec.sourceVocab],
  ];
  if (spec.targetVocab) files.push(['trgVocab', spec.targetVocab]);
  const running = await engine();
  const buffers = [];
  try {
    for (const [kind, path] of files) {
      buffers.push(await readInto(running, path, ALIGNMENT[kind]));
    }
  } catch (error) {
    for (const buffer of buffers) running.api.mozhi_bergamot_buffer_destroy(buffer);
    throw error;
  }
  return guarded((engine) => {
    const { api } = engine;
    const pointers = [
      allocString(engine, locale(spec.source)),
      allocString(engine, locale(spec.target)),
      // No extra configuration: Bergamot ignores Marian's `workspace` (it
      // reserves 5 MB and grows on demand).
      allocString(engine, ''),
    ];
    try {
      const handle = api.mozhi_bergamot_model_create_from_buffers(
        buffers[0],
        buffers[1],
        buffers[2],
        buffers[3] || 0,
        pointers[0],
        pointers[1],
        pointers[2],
        /alphas/.test(spec.model) ? 1 : 0,
      );
      if (!handle) throw failure('engine', `Cannot load ${spec.key}: ${lastError(engine)}`);
      return handle;
    } finally {
      for (const pointer of pointers) api.free(pointer);
    }
  });
}

/** Copies an OPFS file into a new aligned engine buffer. */
async function readInto(running, path, alignment) {
  const handle = await fileHandle(path, false);
  const { api, module } = running;
  let access = null;
  if (typeof handle.createSyncAccessHandle === 'function') {
    access = await handle.createSyncAccessHandle();
  }
  try {
    const bytes = access ? null : new Uint8Array(await (await handle.getFile()).arrayBuffer());
    const size = access ? access.getSize() : bytes.length;
    const buffer = api.mozhi_bergamot_buffer_create(size, alignment);
    if (!buffer) throw failure('engine', `Out of memory for ${path}`);
    const pointer = api.mozhi_bergamot_buffer_data(buffer);
    // Read after allocating: the memory (and so the heap view) may have grown.
    const target = module.mozhi.heap().subarray(pointer, pointer + size);
    if (access) {
      const read = access.read(target, { at: 0 });
      if (read !== size) {
        api.mozhi_bergamot_buffer_destroy(buffer);
        throw failure('storage', `Read ${read} of ${size} bytes of ${path}`);
      }
    } else {
      target.set(bytes);
    }
    return buffer;
  } finally {
    if (access) access.close();
  }
}

/* --- Translation and identification --------------------------------------- */

async function translate({ chain, texts, html, details }) {
  if (!Array.isArray(texts)) throw failure('protocol', 'texts must be a list');
  const [first, second] = await modelsFor(chain);
  return guarded((engine) => {
    const { api, module } = engine;
    const pointers = texts.map((text) => allocString(engine, String(text)));
    const array = api.malloc(Math.max(1, pointers.length) * 4);
    try {
      const heap32 = new Uint32Array(module.mozhi.heap().buffer, array, pointers.length);
      heap32.set(pointers);
      let flags = html ? TRANSLATE_HTML : 0;
      if (details) flags |= TRANSLATE_ALIGNMENT | TRANSLATE_QUALITY;
      const result = api.mozhi_bergamot_translate_ex(
        first,
        second || 0,
        array,
        pointers.length,
        flags,
      );
      if (!result) throw failure('engine', lastError(engine));
      try {
        // The C API's JSON (mozhi_bergamot.h), parsed by the app.
        return module.mozhi.utf8ToString(result);
      } finally {
        api.mozhi_bergamot_free_string(result);
      }
    } finally {
      api.free(array);
      for (const pointer of pointers) api.free(pointer);
    }
  });
}

function readCode(heap, offset) {
  let end = offset;
  while (end < offset + 16 && heap[end] !== 0) end++;
  return String.fromCharCode(...heap.subarray(offset, end));
}

function readDetection(module, pointer) {
  const heap = module.mozhi.heap();
  const view = new DataView(heap.buffer, pointer, DETECTION_SIZE);
  const languages = [];
  for (let i = 0; i < 3; i++) {
    const base = 16 + i * 24;
    const code = readCode(heap, pointer + base);
    if (code && code !== 'un') {
      languages.push({
        code,
        percent: view.getInt32(base + 16, true),
        score: view.getInt32(base + 20, true),
      });
    }
  }
  return {
    language: readCode(heap, pointer),
    languages,
    textBytes: view.getInt32(88, true),
    reliable: view.getInt32(92, true) !== 0,
  };
}

async function identify({ text, hints }) {
  return guarded((engine) => {
    const { api, module } = engine;
    const input = allocString(engine, String(text));
    const length = module.mozhi.lengthBytesUTF8(String(text));
    const hint = hints ? allocString(engine, String(hints)) : 0;
    const out = api.malloc(DETECTION_SIZE);
    try {
      const pass = (flags) => {
        if (!api.mozhi_bergamot_detect(input, length, hint, flags, out)) {
          throw failure('engine', `detect: ${lastError(engine)}`);
        }
        return readDetection(module, out);
      };
      return { precise: pass(0), bestEffort: pass(DETECT_BEST_EFFORT) };
    } finally {
      api.free(out);
      api.free(input);
      if (hint) api.free(hint);
    }
  });
}

/* -------------------------------------------------------------------------- */
/* Storage (OPFS)                                                             */
/* -------------------------------------------------------------------------- */

let rootPromise = null;

function root() {
  if (!rootPromise) {
    rootPromise = navigator.storage
      .getDirectory()
      .then((top) => top.getDirectoryHandle(ROOT_FOLDER, { create: true }));
    rootPromise.catch(() => {
      rootPromise = null;
    });
  }
  return rootPromise;
}

/** The segments of a relative path (no "", "." or ".."). */
function segments(path) {
  const parts = String(path).split('/');
  for (const part of parts) {
    if (!part || part === '.' || part === '..' || part.includes('\\')) {
      throw failure('protocol', `Unsafe path ${path}`);
    }
  }
  return parts;
}

async function directory(parts, create) {
  let current = await root();
  for (const part of parts) {
    current = await current.getDirectoryHandle(part, { create });
  }
  return current;
}

async function fileHandle(path, create) {
  const parts = segments(path);
  const folder = await directory(parts.slice(0, -1), create);
  return folder.getFileHandle(parts[parts.length - 1], { create });
}

async function removePath(path) {
  const parts = segments(path);
  try {
    const folder = await directory(parts.slice(0, -1), false);
    await folder.removeEntry(parts[parts.length - 1], { recursive: true });
  } catch (error) {
    if (!(error instanceof DOMException && error.name === 'NotFoundError')) throw error;
  }
}

async function entries(folder) {
  const result = [];
  for await (const [name, handle] of folder.entries()) result.push([name, handle]);
  return result;
}

async function writeFile(path, bytes) {
  const handle = await fileHandle(path, true);
  if (typeof handle.createSyncAccessHandle === 'function') {
    const access = await handle.createSyncAccessHandle();
    try {
      access.truncate(0);
      let written = 0;
      while (written < bytes.length) {
        written += access.write(bytes.subarray(written), { at: written });
      }
      access.flush();
    } finally {
      access.close();
    }
  } else {
    const writable = await handle.createWritable();
    await writable.write(bytes);
    await writable.close();
  }
}

/**
 * Installed models: every models/<pair>/<version>/ with a valid
 * manifest.json whose files are all there with their sizes.
 */
async function list() {
  const models = [];
  let folder;
  try {
    folder = await directory(['models'], false);
  } catch (error) {
    if (error instanceof DOMException && error.name === 'NotFoundError') return models;
    throw error;
  }
  for (const [pair, pairHandle] of await entries(folder)) {
    if (pairHandle.kind !== 'directory') continue;
    for (const [version, versionHandle] of await entries(pairHandle)) {
      if (versionHandle.kind !== 'directory') continue;
      const installed = await readInstalled(versionHandle);
      if (installed) {
        models.push({ directory: `models/${pair}/${version}`, ...installed });
      }
    }
  }
  return models;
}

async function readInstalled(folder) {
  try {
    const file = await (await folder.getFileHandle(MANIFEST)).getFile();
    const manifest = JSON.parse(await file.text());
    let sizeBytes = 0;
    for (const entry of Object.values(manifest.files || {})) {
      const data = await (await folder.getFileHandle(entry.name)).getFile();
      if (data.size !== entry.size) return null;
      sizeBytes += data.size;
    }
    return { manifest, sizeBytes };
  } catch (_) {
    return null; // incomplete or damaged: not installed (cleanUp removes it)
  }
}

/** The origin's storage use and quota, and the engine's memory (bytes). */
async function usage() {
  const result = { usage: 0, quota: 0, engineMemory: running ? running.module.mozhi.heap().length : 0 };
  try {
    const estimate = await navigator.storage.estimate();
    result.usage = estimate.usage || 0;
    result.quota = estimate.quota || 0;
  } catch (_) {}
  return result;
}

/* --- Downloads ---------------------------------------------------------------- */

// path -> open sync access handle (or a writable fallback state).
const downloads = new Map();

/** Opens (creating) a partial download; its size says where to resume. */
async function downloadOpen({ path, restart }) {
  await downloadClose({ path });
  const handle = await fileHandle(path, true);
  if (typeof handle.createSyncAccessHandle !== 'function') {
    throw failure('unsupported', 'This browser cannot write files from a worker');
  }
  const access = await handle.createSyncAccessHandle();
  if (restart) access.truncate(0);
  downloads.set(path, access);
  return { size: access.getSize() };
}

async function downloadWrite({ path, bytes, at }) {
  const access = downloads.get(path);
  if (!access) throw failure('protocol', `${path} is not open`);
  const data = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let written = 0;
  while (written < data.length) {
    written += access.write(data.subarray(written), { at: at + written });
  }
  return { size: at + written };
}

async function downloadClose({ path }) {
  const access = downloads.get(path);
  if (!access) return;
  downloads.delete(path);
  try {
    access.flush();
  } finally {
    access.close();
  }
}

function hex(buffer) {
  return Array.from(new Uint8Array(buffer), (byte) => byte.toString(16).padStart(2, '0')).join('');
}

async function sha256(bytes) {
  return hex(await crypto.subtle.digest('SHA-256', bytes));
}

/**
 * The size and SHA-256 of a file written with downloadOpen/downloadWrite
 * (an imported file: the app matches it to a catalog file by them).
 */
async function fingerprint({ path }) {
  await downloadClose({ path });
  const bytes = new Uint8Array(await (await (await fileHandle(path, false)).getFile()).arrayBuffer());
  return { size: bytes.length, sha256: await sha256(bytes) };
}

/**
 * Verifies a finished download (size and SHA-256 of the gzip file), then
 * decompresses it into `target` and verifies that too. A mismatch deletes
 * the download. The download is deleted once installed. With `compressed:
 * false` (an imported file that was decompressed already) the file is
 * verified as the decompressed one and written as it is.
 */
async function install({ part, target, size, sha256: expected, uncompressedSize, uncompressedSha256, compressed: gzipped = true }) {
  await downloadClose({ path: part });
  if (gzipped === false) {
    const plain = new Uint8Array(await (await (await fileHandle(part, false)).getFile()).arrayBuffer());
    const digest = await sha256(plain);
    if (plain.length !== uncompressedSize || digest !== uncompressedSha256) {
      await removePath(part);
      throw failure(
        'checksum',
        `${target}: got ${plain.length} bytes with SHA-256 ${digest}, ` +
          `expected ${uncompressedSize} bytes with SHA-256 ${uncompressedSha256}`,
      );
    }
    await writeFile(target, plain);
    await removePath(part);
    return { size: plain.length };
  }
  const compressed = new Uint8Array(await (await (await fileHandle(part, false)).getFile()).arrayBuffer());
  const digest = await sha256(compressed);
  if (compressed.length !== size || digest !== expected) {
    await removePath(part);
    throw failure(
      'checksum',
      `${part}: got ${compressed.length} bytes with SHA-256 ${digest}, ` +
        `expected ${size} bytes with SHA-256 ${expected}`,
    );
  }
  let bytes;
  try {
    const stream = new Blob([compressed]).stream().pipeThrough(new DecompressionStream('gzip'));
    bytes = new Uint8Array(await new Response(stream).arrayBuffer());
  } catch (error) {
    await removePath(part);
    throw failure('checksum', `${part}: not a valid gzip file (${error.message})`);
  }
  const unpacked = await sha256(bytes);
  if (bytes.length !== uncompressedSize || unpacked !== uncompressedSha256) {
    await removePath(part);
    throw failure(
      'checksum',
      `${target}: got ${bytes.length} bytes with SHA-256 ${unpacked}, ` +
        `expected ${uncompressedSize} bytes with SHA-256 ${uncompressedSha256}`,
    );
  }
  await writeFile(target, bytes);
  await removePath(part);
  return { size: bytes.length };
}

/**
 * Completes an install: writes the manifest (a model counts as installed
 * only once it is there), then removes the pair's other versions and the
 * finished downloads.
 */
async function commit({ directory: path, manifest, downloads: downloadPath }) {
  const parts = segments(path);
  if (parts.length !== 3 || parts[0] !== 'models') {
    throw failure('protocol', `Not a model directory: ${path}`);
  }
  await writeFile(`${path}/${MANIFEST}`, new TextEncoder().encode(JSON.stringify(manifest)));
  const pair = await directory(parts.slice(0, 2), false);
  for (const [version] of await entries(pair)) {
    if (version !== parts[2]) await removePath(`models/${parts[1]}/${version}`);
  }
  if (downloadPath) await removePath(downloadPath);
}

async function remove({ path }) {
  for (const [open] of downloads) {
    if (open === path || open.startsWith(`${path}/`)) await downloadClose({ path: open });
  }
  await removePath(path);
}

/** Removes installs that never completed (no manifest). Keeps downloads. */
async function cleanUp() {
  let folder;
  try {
    folder = await directory(['models'], false);
  } catch (_) {
    return;
  }
  for (const [pair, pairHandle] of await entries(folder)) {
    if (pairHandle.kind !== 'directory') continue;
    for (const [version, versionHandle] of await entries(pairHandle)) {
      if (versionHandle.kind === 'directory' && !(await readInstalled(versionHandle))) {
        await removePath(`models/${pair}/${version}`);
      }
    }
  }
}
