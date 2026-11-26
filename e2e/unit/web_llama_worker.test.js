// Tests web/llama/worker.js: OPFS resumable downloads, SHA-256 verification,
// mmproj manifest accounting, cleanup, path traversal rejection, Emscripten FS
// staging, streaming generation, and cancellation across both sync and
// Safari 16 promise-returning OPFS handles.
//
// Run with `npm run test:unit` in e2e/ (Node.js 20+). CI runs it in the web
// end-to-end job.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { describe, test } = require('node:test');

const WORKER_PATH = path.join(
  __dirname,
  '..',
  '..',
  'web',
  'llama',
  'worker.js',
);
const WORKER_SOURCE = fs.readFileSync(WORKER_PATH, 'utf8');

const sha256Hex = (bytes) =>
  crypto.createHash('sha256').update(bytes).digest('hex');

function domError(name, message) {
  return new DOMException(message, name);
}

function fakeStorage({ promises }) {
  const later = (value) =>
    new Promise((resolve) => setTimeout(() => resolve(value), 0));
  const answer = (compute) => (promises ? later(compute()) : compute());

  function fileHandle(name) {
    const file = { kind: 'file', name, bytes: new Uint8Array(0), open: false };
    file.getFile = async () => new Blob([file.bytes]);
    file.createSyncAccessHandle = async () => {
      if (file.open) {
        throw domError('NoModificationAllowedError', `${name} is open`);
      }
      file.open = true;
      let closed = false;
      const check = () => {
        if (closed) throw domError('InvalidStateError', `${name} is closed`);
      };
      return {
        getSize: () => answer(() => (check(), file.bytes.length)),
        truncate: (size) =>
          answer(() => {
            check();
            const next = new Uint8Array(size);
            next.set(file.bytes.subarray(0, size));
            file.bytes = next;
          }),
        write: (data, { at }) =>
          answer(() => {
            check();
            const end = at + data.length;
            if (end > file.bytes.length) {
              const grown = new Uint8Array(end);
              grown.set(file.bytes);
              file.bytes = grown;
            }
            file.bytes.set(data, at);
            return data.length;
          }),
        read: (target, { at }) =>
          answer(() => {
            check();
            const part = file.bytes.subarray(at, at + target.length);
            target.set(part);
            return part.length;
          }),
        flush: () => answer(() => check()),
        close: () => {
          closed = true;
          if (!promises) {
            file.open = false;
            return undefined;
          }
          return later().then(() => {
            file.open = false;
          });
        },
      };
    };
    return file;
  }

  function directoryHandle(name) {
    const children = new Map();
    const folder = { kind: 'directory', name };
    const get = (child, kind, create, make) => {
      const found = children.get(child);
      if (found) {
        if (found.kind !== kind) throw domError('TypeMismatchError', child);
        return found;
      }
      if (!create) throw domError('NotFoundError', `${child} not found`);
      const made = make(child);
      children.set(child, made);
      return made;
    };
    folder.getDirectoryHandle = async (child, options = {}) =>
      get(child, 'directory', options.create, directoryHandle);
    folder.getFileHandle = async (child, options = {}) =>
      get(child, 'file', options.create, fileHandle);
    folder.removeEntry = async (child) => {
      if (!children.delete(child)) throw domError('NotFoundError', child);
    };
    folder.entries = async function* entries() {
      yield* [...children.entries()];
    };
    return folder;
  }

  const top = directoryHandle('');
  return { getDirectory: async () => top };
}

function fakeEmscriptenFs() {
  const files = new Map();
  const dirs = new Set(['/']);
  const unlinked = [];
  return {
    files,
    dirs,
    unlinked,
    mkdir(dir) {
      if (dirs.has(dir)) throw new Error('EEXIST');
      dirs.add(dir);
    },
    open(filePath) {
      files.set(filePath, new Uint8Array(0));
      return { filePath };
    },
    write(stream, buffer, offset, length, position) {
      const existing = files.get(stream.filePath) || new Uint8Array(0);
      const end = position + length;
      const next = end > existing.length ? new Uint8Array(end) : existing;
      if (next !== existing) next.set(existing);
      next.set(buffer.subarray(offset, offset + length), position);
      files.set(stream.filePath, next);
      return length;
    },
    close() {},
    unlink(filePath) {
      unlinked.push(filePath);
      files.delete(filePath);
    },
  };
}

function loadWorker({ storage, mockModule }) {
  const posted = [];
  const self = {
    crypto: crypto.webcrypto,
    onmessage: null,
    postMessage(msg) {
      posted.push(msg);
    },
  };
  const navigator = { storage };
  const importScripts = () => {
    if (!mockModule) throw new Error('llama-engine.js missing');
    self.loadMozhiLlama = async () => mockModule;
  };
  const fetch = async () => ({ ok: Boolean(mockModule), status: mockModule ? 200 : 404 });

  const exported = new Function(
    'self',
    'navigator',
    'importScripts',
    'fetch',
    `${WORKER_SOURCE}\nreturn { OPERATIONS };`,
  )(self, navigator, importScripts, fetch);

  let nextId = 1;
  async function rpc(op, params = {}) {
    const id = nextId++;
    const before = posted.length;
    self.onmessage({ data: { id, op, ...params } });
    while (true) {
      for (let i = before; i < posted.length; i++) {
        if (posted[i].id === id && typeof posted[i].ok === 'boolean') {
          return {
            response: posted[i],
            deltas: posted
              .slice(before, i)
              .filter((m) => m.id === id && typeof m.delta === 'string')
              .map((m) => m.delta),
          };
        }
      }
      await new Promise((r) => setTimeout(r, 2));
    }
  }

  return { ...exported, self, posted, rpc };
}

for (const promises of [false, true]) {
  const label = promises
    ? 'web_llama_worker with Safari 16 promise handles'
    : 'web_llama_worker with current sync handles';

  describe(label, () => {
    test('resumes download, verifies SHA-256, commits model + mmproj, lists, and cleans up', async () => {
      const storage = fakeStorage({ promises });
      const { OPERATIONS } = loadWorker({ storage });

      const modelBytes = crypto.randomBytes(1500);
      const projBytes = crypto.randomBytes(600);
      const partPath = 'models/.dl/gemma/model.gguf.part';
      const projPart = 'models/.dl/gemma/mmproj.gguf.part';

      // Part 1 of resumable download
      assert.deepEqual(
        await OPERATIONS.downloadOpen({ path: partPath, restart: true }),
        { size: 0 },
      );
      await OPERATIONS.downloadWrite({
        path: partPath,
        bytes: modelBytes.subarray(0, 700),
        at: 0,
      });
      await OPERATIONS.downloadClose({ path: partPath });

      // Partial size reports 700 bytes
      assert.deepEqual(
        await OPERATIONS.partialSize({ paths: [partPath, projPart] }),
        { size: 700 },
      );

      // Reopen without restart and finish remaining bytes
      assert.deepEqual(
        await OPERATIONS.downloadOpen({ path: partPath, restart: false }),
        { size: 700 },
      );
      await OPERATIONS.downloadWrite({
        path: partPath,
        bytes: modelBytes.subarray(700),
        at: 700,
      });
      await OPERATIONS.install({
        part: partPath,
        target: 'models/gemma/model.gguf',
        size: modelBytes.length,
        sha256: sha256Hex(modelBytes),
      });

      // Download & install mmproj
      await OPERATIONS.downloadOpen({ path: projPart, restart: true });
      await OPERATIONS.downloadWrite({ path: projPart, bytes: projBytes, at: 0 });
      await OPERATIONS.install({
        part: projPart,
        target: 'models/gemma/mmproj.gguf',
        size: projBytes.length,
        sha256: sha256Hex(projBytes),
      });

      const manifest = {
        schemaVersion: 1,
        id: 'gemma',
        name: 'model.gguf',
        size: modelBytes.length,
        mmproj: { name: 'mmproj.gguf', size: projBytes.length },
      };
      await OPERATIONS.commit({
        directory: 'models/gemma',
        downloads: 'models/.dl/gemma',
        manifest,
      });

      const listed = await OPERATIONS.list();
      assert.equal(listed.length, 1);
      assert.equal(listed[0].manifest.id, 'gemma');
      assert.equal(listed[0].sizeBytes, modelBytes.length + projBytes.length);
      assert.deepEqual(await OPERATIONS.listModels(), ['gemma']);

      // Orphan incomplete directory is purged by cleanUp while valid model stays
      await OPERATIONS.downloadOpen({
        path: 'models/orphan/partial.gguf',
        restart: true,
      });
      await OPERATIONS.downloadClose({ path: 'models/orphan/partial.gguf' });
      await OPERATIONS.cleanUp();
      assert.deepEqual(await OPERATIONS.listModels(), ['gemma']);

      await OPERATIONS.remove({ path: 'models/gemma' });
      assert.deepEqual(await OPERATIONS.listModels(), []);
    });

    test('install rejects checksum mismatch and deletes corrupted partial file', async () => {
      const storage = fakeStorage({ promises });
      const { OPERATIONS } = loadWorker({ storage });
      const partPath = 'models/.dl/bad/model.gguf.part';
      await OPERATIONS.downloadOpen({ path: partPath, restart: true });
      await OPERATIONS.downloadWrite({
        path: partPath,
        bytes: new Uint8Array([1, 2, 3, 4]),
        at: 0,
      });
      await assert.rejects(
        () =>
          OPERATIONS.install({
            part: partPath,
            target: 'models/bad/model.gguf',
            size: 4,
            sha256: '0'.repeat(64),
          }),
        (err) => err.kind === 'checksum',
      );
      assert.deepEqual(await OPERATIONS.partialSize({ paths: [partPath] }), {
        size: 0,
      });
    });

    test('rejects unsafe path traversal', async () => {
      const storage = fakeStorage({ promises });
      const { OPERATIONS } = loadWorker({ storage });
      await assert.rejects(
        () => OPERATIONS.downloadOpen({ path: '../escape.gguf', restart: true }),
        (err) => err.kind === 'protocol',
      );
      await assert.rejects(
        () => OPERATIONS.remove({ path: 'models\\bad' }),
        (err) => err.kind === 'protocol',
      );
    });

    test('stages OPFS model into Emscripten FS, streams generate deltas, and unlinks on unload', async () => {
      const storage = fakeStorage({ promises });
      const emFs = fakeEmscriptenFs();
      let loadedArgs = null;
      const mockModule = {
        FS: emFs,
        async loadModel(fsPath, nThreads, nCtx) {
          loadedArgs = { fsPath, nThreads, nCtx };
          return { path: fsPath, contextSize: nCtx };
        },
        async unloadModel() {},
        async countTokens(messages) {
          return messages.length * 5;
        },
        async generate(_req, onDelta) {
          onDelta('Bon');
          onDelta('jour');
          return { promptTokens: 5, generatedTokens: 2, finishReason: 'stop' };
        },
      };
      const { OPERATIONS, rpc } = loadWorker({ storage, mockModule });

      const modelBytes = crypto.randomBytes(256);
      const partPath = 'models/.dl/m1/model.gguf.part';
      await OPERATIONS.downloadOpen({ path: partPath, restart: true });
      await OPERATIONS.downloadWrite({ path: partPath, bytes: modelBytes, at: 0 });
      await OPERATIONS.install({
        part: partPath,
        target: 'models/m1/model.gguf',
        size: modelBytes.length,
        sha256: sha256Hex(modelBytes),
      });

      const loadRes = await rpc('load', {
        path: 'models/m1/model.gguf',
        contextSize: 2048,
        threads: 2,
      });
      assert.equal(loadRes.response.ok, true);
      assert.deepEqual(loadedArgs, {
        fsPath: '/models/m1/model.gguf',
        nThreads: 2,
        nCtx: 2048,
      });
      assert.deepEqual(
        Array.from(emFs.files.get('/models/m1/model.gguf')),
        Array.from(modelBytes),
      );

      const tokRes = await rpc('countTokens', {
        messages: [{ role: 'user', content: 'Hi' }],
      });
      assert.equal(tokRes.response.result, 5);

      const genRes = await rpc('generate', {
        messages: [{ role: 'user', content: 'Hello' }],
      });
      assert.equal(genRes.response.ok, true);
      assert.deepEqual(genRes.deltas, ['Bon', 'jour']);
      assert.equal(genRes.response.result.generatedTokens, 2);

      const unloadRes = await rpc('unload');
      assert.equal(unloadRes.response.ok, true);
      assert.ok(emFs.unlinked.includes('/models/m1/model.gguf'));
    });
  });
}
