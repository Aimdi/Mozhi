/*
 * Mozhi's on-device AI WebAssembly worker: runs llama.cpp compiled to WASM
 * (by packages/llama_engine/tool/build_wasm.sh) with GGUF models (and
 * optional multimodal mmproj files) stored in the browser's Origin Private
 * File System (OPFS).
 *
 * Copyright (c) 2026 Mozhi contributors. MIT License.
 *
 * Protocol (matching web/bergamot/worker.js):
 *   page -> worker  {id, op, ...arguments}
 *   worker -> page  {id, ok: true, result}
 *                 | {id, ok: false, error: {kind, message}}
 *                 | {id, delta: string}   (streaming token chunks during generate)
 *
 * Nothing here touches the network except loading llama-engine.js /
 * llama-engine.wasm from this origin: model files arrive from the app
 * (which downloads them through its own HTTP client) and are stored,
 * SHA-256 verified, and staged into Emscripten's virtual FS here.
 */
'use strict';

const ENGINE_SCRIPT = 'llama-engine.js';
const ENGINE_WASM = 'llama-engine.wasm';
const ABI_VERSION = 2;
const ROOT_FOLDER = 'llama';
const MANIFEST = 'manifest.json';
const STAGE_CHUNK_BYTES = 4 * 1024 * 1024;

let moduleFactory = null;
let instance = null;
let loadedModel = null;
let loadedVirtualPath = null;
let cancelled = false;
let queue = Promise.resolve();
let rootPromise = null;

// path -> open FileSystemSyncAccessHandle (for resumable OPFS writes).
const downloads = new Map();

self.onmessage = (event) => {
  const message = event.data;
  if (message && message.op === 'cancel') {
    cancelled = true;
    self.postMessage({ id: message.id, ok: true, result: null });
    return;
  }
  queue = queue.then(() => handle(message));
};

async function handle(message) {
  const id = message && message.id;
  try {
    const operation = OPERATIONS[message && message.op];
    if (!operation) throw failure('protocol', `Unknown op ${message && message.op}`);
    const result = await operation(message, id);
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
  if (typeof DOMException !== 'undefined' && error instanceof DOMException) {
    const kind = error.name === 'NotFoundError' ? 'missing' : 'storage';
    return { kind, message: `${error.name}: ${error.message}` };
  }
  return { kind: 'engine', message: String((error && error.message) || error) };
}

/* -------------------------------------------------------------------------- */
/* Capabilities & Engine                                                      */
/* -------------------------------------------------------------------------- */

async function probe() {
  const hasWasm = typeof WebAssembly === 'object';
  const hasDigest = !!(self.crypto && self.crypto.subtle);
  let hasOpfs = false;
  let hasSyncAccess = false;
  try {
    await opfsRoot();
    hasOpfs = true;
    hasSyncAccess =
      typeof FileSystemFileHandle === 'function' &&
      'createSyncAccessHandle' in FileSystemFileHandle.prototype;
  } catch (_) {}

  let hasEngine = false;
  if (hasWasm) {
    try {
      const response = await fetch(ENGINE_WASM, { method: 'HEAD', cache: 'no-cache' });
      hasEngine = response.ok || response.status === 405;
    } catch (_) {
      hasEngine = false;
    }
  }
  return {
    supported: hasWasm && hasOpfs && hasDigest && hasEngine,
    wasm: hasWasm,
    opfs: hasOpfs,
    syncAccess: hasSyncAccess,
    digest: hasDigest,
    engineAvailable: hasEngine,
    abiVersion: ABI_VERSION,
  };
}

async function ensureEngine() {
  if (instance) return instance;
  if (typeof WebAssembly !== 'object') {
    throw failure('unsupported', 'WebAssembly is not available in this browser');
  }
  if (!moduleFactory) {
    try {
      importScripts(ENGINE_SCRIPT);
    } catch (error) {
      throw failure('unsupported', `Cannot load ${ENGINE_SCRIPT}: ${error}`);
    }
    if (typeof self.loadMozhiLlama !== 'function') {
      throw failure('unsupported', `${ENGINE_SCRIPT} did not export loadMozhiLlama`);
    }
    moduleFactory = self.loadMozhiLlama;
  }
  instance = await moduleFactory({
    locateFile: (path) => (path.endsWith('.wasm') ? ENGINE_WASM : path),
  });
  return instance;
}

/* -------------------------------------------------------------------------- */
/* OPFS Storage                                                               */
/* -------------------------------------------------------------------------- */

function opfsRoot() {
  if (!rootPromise) {
    if (!navigator.storage || typeof navigator.storage.getDirectory !== 'function') {
      return Promise.reject(
        failure('unsupported', 'Origin Private File System is not available'),
      );
    }
    rootPromise = navigator.storage
      .getDirectory()
      .then((root) => root.getDirectoryHandle(ROOT_FOLDER, { create: true }));
    rootPromise.catch(() => {
      rootPromise = null;
    });
  }
  return rootPromise;
}

function segments(path) {
  const parts = String(path || '').split('/');
  for (const part of parts) {
    if (!part || part === '.' || part === '..' || part.includes('\\')) {
      throw failure('protocol', `Unsafe path ${path}`);
    }
  }
  return parts;
}

async function directory(parts, create) {
  let current = await opfsRoot();
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

async function opfsFileExists(path) {
  try {
    await fileHandle(path, false);
    return true;
  } catch (_) {
    return false;
  }
}

async function removePath(path) {
  const parts = segments(path);
  try {
    const folder = await directory(parts.slice(0, -1), false);
    await folder.removeEntry(parts[parts.length - 1], { recursive: true });
  } catch (error) {
    if (!(typeof DOMException !== 'undefined' && error instanceof DOMException && error.name === 'NotFoundError')) {
      throw error;
    }
  }
}

async function dirEntries(folder) {
  const result = [];
  for await (const [name, handle] of folder.entries()) {
    result.push([name, handle]);
  }
  return result;
}

async function writeOpfsFile(path, bytes) {
  const handle = await fileHandle(path, true);
  if (typeof handle.createSyncAccessHandle === 'function') {
    const access = await handle.createSyncAccessHandle();
    try {
      await access.truncate(0);
      let written = 0;
      while (written < bytes.length) {
        written += await access.write(bytes.subarray(written), { at: written });
      }
      await access.flush();
    } finally {
      await access.close();
    }
  } else {
    const writable = await handle.createWritable();
    await writable.write(bytes);
    await writable.close();
  }
}

function hex(buffer) {
  return Array.from(new Uint8Array(buffer), (b) => b.toString(16).padStart(2, '0')).join('');
}

async function sha256(bytes) {
  if (!self.crypto || !self.crypto.subtle) {
    throw failure('unsupported', 'Web Crypto SHA-256 is not available');
  }
  return hex(await self.crypto.subtle.digest('SHA-256', bytes));
}

async function readInstalled(folder) {
  try {
    const manifestFile = await (await folder.getFileHandle(MANIFEST)).getFile();
    const manifest = JSON.parse(await manifestFile.text());
    if (!manifest || manifest.schemaVersion !== 1 || !manifest.id || !manifest.name) {
      return null;
    }
    const modelFile = await (await folder.getFileHandle(manifest.name)).getFile();
    if (modelFile.size !== manifest.size) return null;
    let sizeBytes = modelFile.size;
    if (manifest.mmproj && typeof manifest.mmproj === 'object') {
      const projFile = await (await folder.getFileHandle(manifest.mmproj.name)).getFile();
      if (projFile.size !== manifest.mmproj.size) return null;
      sizeBytes += projFile.size;
    }
    return { manifest, sizeBytes };
  } catch (_) {
    return null;
  }
}

async function list() {
  const models = [];
  let folder;
  try {
    folder = await directory(['models'], false);
  } catch (error) {
    if (typeof DOMException !== 'undefined' && error instanceof DOMException && error.name === 'NotFoundError') {
      return models;
    }
    throw error;
  }
  for (const [id, handle] of await dirEntries(folder)) {
    if (handle.kind !== 'directory' || id.startsWith('.')) continue;
    const installed = await readInstalled(handle);
    if (installed && installed.manifest.id === id) {
      models.push({ directory: `models/${id}`, ...installed });
    }
  }
  return models;
}

async function partialSize({ paths }) {
  let total = 0;
  for (const path of Array.isArray(paths) ? paths : []) {
    try {
      const file = await (await fileHandle(path, false)).getFile();
      total += file.size;
    } catch (_) {
      // Missing partial file contributes 0 bytes.
    }
  }
  return { size: total };
}

async function downloadOpen({ path, restart }) {
  await downloadClose({ path });
  const handle = await fileHandle(path, true);
  if (typeof handle.createSyncAccessHandle !== 'function') {
    throw failure('unsupported', 'This browser cannot write files from a worker');
  }
  const access = await handle.createSyncAccessHandle();
  if (restart) await access.truncate(0);
  downloads.set(path, access);
  return { size: await access.getSize() };
}

async function downloadWrite({ path, bytes, at }) {
  const access = downloads.get(path);
  if (!access) throw failure('protocol', `${path} is not open`);
  const data = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let written = 0;
  while (written < data.length) {
    written += await access.write(data.subarray(written), { at: at + written });
  }
  return { size: at + written };
}

async function downloadClose({ path }) {
  const access = downloads.get(path);
  if (!access) return;
  downloads.delete(path);
  try {
    await access.flush();
  } finally {
    await access.close();
  }
}

async function install({ part, target, size, sha256: expected }) {
  await downloadClose({ path: part });
  const handle = await fileHandle(part, false);
  const bytes = new Uint8Array(await (await handle.getFile()).arrayBuffer());
  const digest = await sha256(bytes);
  if (bytes.length !== size || digest !== expected) {
    await removePath(part);
    throw failure(
      'checksum',
      `${target}: got ${bytes.length} bytes with SHA-256 ${digest}, ` +
        `expected ${size} bytes with SHA-256 ${expected}`,
    );
  }
  await writeOpfsFile(target, bytes);
  await removePath(part);
  return { size: bytes.length };
}

async function commit({ directory: dir, downloads: dlDir, manifest }) {
  const bytes = new TextEncoder().encode(JSON.stringify(manifest));
  await writeOpfsFile(`${dir}/${MANIFEST}`, bytes);
  if (dlDir) {
    await removePath(dlDir);
  }
}

async function remove({ path }) {
  await downloadClose({ path });
  await removePath(path);
}

async function cleanUp() {
  let folder;
  try {
    folder = await directory(['models'], false);
  } catch (_) {
    return;
  }
  for (const [id, handle] of await dirEntries(folder)) {
    if (handle.kind !== 'directory') continue;
    if (id.startsWith('.') || !(await readInstalled(handle))) {
      try {
        await folder.removeEntry(id, { recursive: true });
      } catch (_) {}
    }
  }
}

/* -------------------------------------------------------------------------- */
/* Emscripten Virtual FS Staging & Inference                                  */
/* -------------------------------------------------------------------------- */

function ensureEmscriptenDirs(FS, virtualPath) {
  const parts = virtualPath.split('/').filter(Boolean);
  let current = '';
  for (let i = 0; i < parts.length - 1; i++) {
    current += '/' + parts[i];
    try {
      FS.mkdir(current);
    } catch (_) {
      // Directory already exists.
    }
  }
}

function unlinkVirtualFile(mod, virtualPath) {
  if (!mod || !mod.FS || !virtualPath) return;
  try {
    mod.FS.unlink(virtualPath);
  } catch (_) {
    // Already removed or never staged.
  }
}

/**
 * Streams a GGUF file stored in OPFS into Emscripten's virtual FS so
 * llama.cpp (`fopen` / `std::ifstream`) can read it directly.
 */
async function stageOpfsFileToEmscriptenFs(FS, opfsPath) {
  const virtualPath = opfsPath.startsWith('/') ? opfsPath : `/${opfsPath}`;
  if (loadedVirtualPath && loadedVirtualPath !== virtualPath) {
    unlinkVirtualFile(instance, loadedVirtualPath);
    loadedVirtualPath = null;
  }
  ensureEmscriptenDirs(FS, virtualPath);

  const handle = await fileHandle(opfsPath, false);
  let access = null;
  if (typeof handle.createSyncAccessHandle === 'function') {
    access = await handle.createSyncAccessHandle();
  }
  const stream = FS.open(virtualPath, 'w+');
  try {
    if (access) {
      const total = await access.getSize();
      const buffer = new Uint8Array(Math.min(STAGE_CHUNK_BYTES, Math.max(1, total)));
      let offset = 0;
      while (offset < total) {
        const len = Math.min(buffer.length, total - offset);
        const slice = buffer.subarray(0, len);
        const read = await access.read(slice, { at: offset });
        if (read <= 0) break;
        FS.write(stream, slice, 0, read, offset);
        offset += read;
      }
    } else {
      const file = await handle.getFile();
      const total = file.size;
      let offset = 0;
      while (offset < total) {
        const end = Math.min(total, offset + STAGE_CHUNK_BYTES);
        const chunk = new Uint8Array(await file.slice(offset, end).arrayBuffer());
        FS.write(stream, chunk, 0, chunk.length, offset);
        offset += chunk.length;
      }
    }
  } finally {
    FS.close(stream);
    if (access) await access.close();
  }
  return virtualPath;
}

async function loadModel(message) {
  const mod = await ensureEngine();
  const path = String(message.path || '');
  if (!path) throw failure('protocol', 'Missing model path');
  const nCtx = Number(message.contextSize || 4096);
  const nThreads = Number(message.threads || 1);
  if (typeof mod.loadModel !== 'function') {
    throw failure('unsupported', 'WASM llama engine does not expose loadModel');
  }
  let fsPath = path;
  if (mod.FS && (await opfsFileExists(path))) {
    fsPath = await stageOpfsFileToEmscriptenFs(mod.FS, path);
    loadedVirtualPath = fsPath;
  }
  const info = await mod.loadModel(fsPath, nThreads, nCtx);
  loadedModel = path;
  return info || { path, contextSize: nCtx };
}

async function unloadModel() {
  if (instance && typeof instance.unloadModel === 'function') {
    await instance.unloadModel();
  }
  if (loadedVirtualPath) {
    unlinkVirtualFile(instance, loadedVirtualPath);
    loadedVirtualPath = null;
  }
  loadedModel = null;
}

async function countTokens(message) {
  const mod = await ensureEngine();
  if (!loadedModel) throw failure('notLoaded', 'No model is loaded');
  if (typeof mod.countTokens !== 'function') {
    throw failure('unsupported', 'WASM llama engine does not expose countTokens');
  }
  return mod.countTokens(message.messages || []);
}

async function generate(message, requestId) {
  const mod = await ensureEngine();
  if (!loadedModel) throw failure('notLoaded', 'No model is loaded');
  if (typeof mod.generate !== 'function') {
    throw failure('unsupported', 'WASM llama engine does not expose generate');
  }
  cancelled = false;
  const stats = await mod.generate(
    {
      messages: message.messages || [],
      sampling: message.sampling || {},
      maxTokens: message.maxTokens || 512,
      jsonOutput: Boolean(message.jsonOutput),
      stop: message.stop || [],
    },
    (delta) => {
      if (cancelled) return false;
      if (delta) self.postMessage({ id: requestId, delta: String(delta) });
      return true;
    },
  );
  if (cancelled) throw failure('cancelled', 'cancelled');
  return stats || {
    promptTokens: 0,
    generatedTokens: 0,
    promptMs: 0,
    generateMs: 0,
    finishReason: 'stop',
  };
}

async function listOpfsModels() {
  const installed = await list();
  return installed.map((entry) => entry.manifest.id);
}

const OPERATIONS = {
  probe,
  load: loadModel,
  unload: unloadModel,
  countTokens,
  generate,
  list,
  listModels: listOpfsModels,
  partialSize,
  downloadOpen,
  downloadWrite,
  downloadClose,
  install,
  commit,
  remove,
  cleanUp,
};
