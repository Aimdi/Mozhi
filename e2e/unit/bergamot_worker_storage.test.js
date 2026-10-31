// The on-device engine's worker (web/bergamot/worker.js) and the browser's
// private storage: downloads, imports and model files are written and read
// through FileSystemSyncAccessHandle, whose methods return their results
// in current browsers and returned promises in older ones (Safari 16,
// Chrome before 108). Both kinds of handle, faked here with the browser's
// rules (one open handle per file), must give the same files.
//
// Run with `npm run test:unit` in e2e/ (Node.js 20 or newer; nothing to
// install). CI runs it in the web end-to-end job.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { describe, test } = require('node:test');
const zlib = require('node:zlib');

const WORKER = path.join(__dirname, '..', '..', 'web', 'bergamot', 'worker.js');

/** A DOMException as the browser throws it. */
function domError(name, message) {
  return new DOMException(message, name);
}

/**
 * An in-memory Origin Private File System. With [promises], a sync access
 * handle answers like Safari 16 did: every method returns a promise, and
 * `close` lets the file be opened again only once it has resolved.
 */
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

/** worker.js with [storage] as `navigator.storage`, and its functions. */
function loadWorker(storage) {
  const source = fs.readFileSync(WORKER, 'utf8');
  const self = { postMessage() {}, isSecureContext: true };
  const navigator = { storage };
  return new Function(
    'self',
    'navigator',
    `${source}\nreturn { OPERATIONS, readInto, writeFile };`,
  )(self, navigator);
}

/** An engine stand-in: buffers are slices of one heap. */
function fakeEngine(size = 4096) {
  const heap = new Uint8Array(size);
  const buffers = new Map();
  let next = 1;
  return {
    heap,
    buffers,
    running: {
      api: {
        mozhi_bergamot_buffer_create(length) {
          const id = next++;
          buffers.set(id, { offset: 64, length });
          return id;
        },
        mozhi_bergamot_buffer_data: (id) => buffers.get(id).offset,
        mozhi_bergamot_buffer_destroy: (id) => buffers.delete(id),
      },
      module: { mozhi: { heap: () => heap } },
    },
  };
}

const sha256 = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');

for (const promises of [false, true]) {
  const kind = promises ? 'promise-returning handles (Safari 16)' : 'current handles';

  describe(`the worker's storage with ${kind}`, () => {
    test('a download is written in parts, resumed, verified and installed', async () => {
      const { OPERATIONS } = loadWorker(fakeStorage({ promises }));
      const part = '.downloads/en-de/1/model.bin.part';
      const bytes = Uint8Array.from({ length: 300 }, (_, i) => i % 251);

      assert.deepEqual(await OPERATIONS.downloadOpen({ path: part }), { size: 0 });
      assert.deepEqual(
        await OPERATIONS.downloadWrite({ path: part, bytes: bytes.subarray(0, 120), at: 0 }),
        { size: 120 },
      );
      await OPERATIONS.downloadClose({ path: part });
      // Opened again at once: the handle was closed before.
      assert.deepEqual(await OPERATIONS.downloadOpen({ path: part }), { size: 120 });
      assert.deepEqual(
        await OPERATIONS.downloadWrite({ path: part, bytes: bytes.subarray(120), at: 120 }),
        { size: 300 },
      );
      assert.deepEqual(await OPERATIONS.fingerprint({ path: part }), {
        size: 300,
        sha256: sha256(bytes),
      });

      assert.deepEqual(
        await OPERATIONS.install({
          part,
          target: 'models/en-de/1/model.bin',
          uncompressedSize: 300,
          uncompressedSha256: sha256(bytes),
          compressed: false,
        }),
        { size: 300 },
      );
      await OPERATIONS.commit({
        directory: 'models/en-de/1',
        manifest: { files: { model: { name: 'model.bin', size: 300 } } },
      });
      const [installed] = await OPERATIONS.list();
      assert.equal(installed.directory, 'models/en-de/1');
      assert.equal(installed.sizeBytes, 300);
    });

    test('a restarted download starts empty', async () => {
      const { OPERATIONS } = loadWorker(fakeStorage({ promises }));
      const part = '.downloads/en-de/1/vocab.spm.part';
      await OPERATIONS.downloadOpen({ path: part });
      await OPERATIONS.downloadWrite({ path: part, bytes: new Uint8Array(50), at: 0 });
      assert.deepEqual(await OPERATIONS.downloadOpen({ path: part, restart: true }), {
        size: 0,
      });
      await OPERATIONS.downloadClose({ path: part });
    });

    test('a gzip download is decompressed into place', async () => {
      const { OPERATIONS } = loadWorker(fakeStorage({ promises }));
      const part = '.downloads/en-de/1/lex.bin.gz.part';
      const plain = new TextEncoder().encode('shortlist '.repeat(40));
      const gzip = new Uint8Array(zlib.gzipSync(plain));
      await OPERATIONS.downloadOpen({ path: part });
      await OPERATIONS.downloadWrite({ path: part, bytes: gzip, at: 0 });
      assert.deepEqual(
        await OPERATIONS.install({
          part,
          target: 'models/en-de/1/lex.bin',
          size: gzip.length,
          sha256: sha256(gzip),
          uncompressedSize: plain.length,
          uncompressedSha256: sha256(plain),
        }),
        { size: plain.length },
      );
    });

    test('a model file is read whole into an engine buffer, twice', async () => {
      const worker = loadWorker(fakeStorage({ promises }));
      const bytes = Uint8Array.from({ length: 700 }, (_, i) => (i * 7) % 256);
      await worker.writeFile('models/en-de/1/model.bin', bytes);
      // Written again (an update): the file is replaced, not appended to.
      await worker.writeFile('models/en-de/1/model.bin', bytes.subarray(0, 500));

      const engine = fakeEngine();
      for (let i = 0; i < 2; i++) {
        const buffer = await worker.readInto(engine.running, 'models/en-de/1/model.bin', 64);
        const { offset, length } = engine.buffers.get(buffer);
        assert.equal(length, 500);
        assert.deepEqual(engine.heap.subarray(offset, offset + length), bytes.subarray(0, 500));
      }
    });

    test('a missing model file is reported as missing', async () => {
      const { OPERATIONS } = loadWorker(fakeStorage({ promises }));
      await assert.rejects(
        OPERATIONS.fingerprint({ path: 'models/en-de/1/none.bin' }),
        (error) => error instanceof DOMException && error.name === 'NotFoundError',
      );
    });
  });
}
