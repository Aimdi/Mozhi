/*
 * Mozhi's on-device AI WebAssembly worker: runs llama.cpp compiled to WASM
 * (by packages/llama_engine/tool/build_wasm.sh) with GGUF models stored in
 * the browser's Origin Private File System (OPFS).
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
 * llama-engine.wasm from this origin.
 */
'use strict';

const ENGINE_SCRIPT = 'llama-engine.js';
const ENGINE_WASM = 'llama-engine.wasm';
const ABI_VERSION = 2;
const ROOT_FOLDER = 'llama';

let moduleFactory = null;
let instance = null;
let loadedModel = null;
let cancelled = false;
let queue = Promise.resolve();

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

async function probe() {
  const hasWasm = typeof WebAssembly === 'object';
  const hasOpfs =
    typeof navigator !== 'undefined' &&
    navigator.storage &&
    typeof navigator.storage.getDirectory === 'function';
  let hasEngine = false;
  if (hasWasm) {
    try {
      const response = await fetch(ENGINE_WASM, { method: 'HEAD' });
      hasEngine = response.ok;
    } catch (_) {
      hasEngine = false;
    }
  }
  return {
    supported: hasWasm && hasOpfs && hasEngine,
    wasm: hasWasm,
    opfs: hasOpfs,
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

async function opfsRoot() {
  if (!navigator.storage || !navigator.storage.getDirectory) {
    throw failure('unsupported', 'Origin Private File System is not available');
  }
  const root = await navigator.storage.getDirectory();
  return root.getDirectoryHandle(ROOT_FOLDER, { create: true });
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
  const info = await mod.loadModel(path, nThreads, nCtx);
  loadedModel = path;
  return info || { path, contextSize: nCtx };
}

async function unloadModel() {
  if (instance && typeof instance.unloadModel === 'function') {
    await instance.unloadModel();
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
  const dir = await opfsRoot();
  const names = [];
  for await (const [name] of dir.entries()) {
    names.push(name);
  }
  return names;
}

const OPERATIONS = {
  probe,
  load: loadModel,
  unload: unloadModel,
  countTokens,
  generate,
  listModels: listOpfsModels,
};
