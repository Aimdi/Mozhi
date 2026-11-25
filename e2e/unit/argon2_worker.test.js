// Tests web/backup/argon2_worker.js: BLAKE2b (RFC 7693), Argon2id v0x13
// (RFC 9106 + Dart parity vectors), Web Worker RPC protocol, and sensitive
// buffer zeroing.
//
// Run with `npm run test:unit` in e2e/ (Node.js 20+). CI runs it in the web
// end-to-end job.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { describe, test } = require('node:test');
const vm = require('node:vm');

const WORKER_PATH = path.join(
  __dirname,
  '..',
  '..',
  'web',
  'backup',
  'argon2_worker.js',
);
const WORKER_SOURCE = fs.readFileSync(WORKER_PATH, 'utf8');

const toHex = (bytes) =>
  Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
const utf8 = (text) => new TextEncoder().encode(text);

function loadDirect() {
  const mod = { exports: {} };
  const context = {
    module: mod,
    exports: mod.exports,
    Uint8Array,
    Uint32Array,
    ArrayBuffer,
    Math,
    Number,
    Array,
    Error,
    RangeError,
    TypeError,
    String,
  };
  vm.runInNewContext(WORKER_SOURCE, context, { filename: WORKER_PATH });
  return mod.exports;
}

function loadAsWorker() {
  const posted = [];
  const self = {
    onmessage: null,
    postMessage(message, transfer) {
      posted.push({ message, transfer });
    },
  };
  const context = {
    self,
    globalThis: {},
    Uint8Array,
    Uint32Array,
    ArrayBuffer,
    Math,
    Number,
    Array,
    Error,
    RangeError,
    TypeError,
    String,
  };
  vm.runInNewContext(WORKER_SOURCE, context, { filename: WORKER_PATH });
  return { self, posted };
}

describe('argon2_worker.js', () => {
  const { argon2id, blake2b } = loadDirect();

  test('BLAKE2b-512 matches RFC 7693 vectors', () => {
    assert.equal(
      toHex(blake2b(utf8(''), 64)),
      '786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419' +
        'd25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce',
    );
    assert.equal(
      toHex(blake2b(utf8('abc'), 64)),
      'ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d1' +
        '7d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923',
    );
  });

  test('Argon2id matches RFC 9106 Section 5.3 and Dart parity vectors', () => {
    const rfc = argon2id({
      passphraseBytes: new Uint8Array(32).fill(0x01),
      saltBytes: new Uint8Array(16).fill(0x02),
      secret: new Uint8Array(8).fill(0x03),
      associatedData: new Uint8Array(12).fill(0x04),
      memoryKiB: 32,
      iterations: 3,
      parallelism: 4,
      hashLength: 32,
    });
    assert.equal(
      toHex(rfc),
      '0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659',
    );

    const vectors = [
      {
        passphrase: 'password',
        salt: 'somesalt',
        memoryKiB: 256,
        iterations: 2,
        parallelism: 1,
        hashLength: 32,
        expected:
          '9dfeb910e80bad0311fee20f9c0e2b12c17987b4cac90c2ef54d5b3021c68bfe',
      },
      {
        passphrase: 'correct horse battery staple',
        salt: '0123456789abcdef',
        memoryKiB: 64,
        iterations: 1,
        parallelism: 1,
        hashLength: 32,
        expected:
          '6aae361c12fe20f022b47b290a1c3ff26c792515f68c50e44e696c06c9301ffd',
      },
      {
        passphrase: 'வணக்கம் Vi\u1EC7t nam 🔐',
        salt: 'mozhi-backup-salt-16b',
        memoryKiB: 1024,
        iterations: 3,
        parallelism: 2,
        hashLength: 32,
        expected:
          'a039a0698117dda07ee25dc1883142573f5398b96c658b487c67e23b7e77cb7c',
      },
      {
        passphrase: 'multi-lane-passphrase',
        salt: 'four-lanes-salt!',
        memoryKiB: 128,
        iterations: 2,
        parallelism: 4,
        hashLength: 64,
        expected:
          'ded38a84837946fc963ee944d6190fd2bc4afaae54094d3800165a5df38c48a2' +
          '584cf6f0b4f5384dc375138395b6c8f4f3d60db4688e4bad60d197fd560ee35c',
      },
    ];
    for (const v of vectors) {
      const actual = argon2id({
        passphraseBytes: utf8(v.passphrase),
        saltBytes: utf8(v.salt),
        memoryKiB: v.memoryKiB,
        iterations: v.iterations,
        parallelism: v.parallelism,
        hashLength: v.hashLength,
      });
      assert.equal(toHex(actual), v.expected);
    }
  });

  test('worker RPC derives key, transfers buffer, zeroes passphrase, and handles errors', () => {
    const { self, posted } = loadAsWorker();
    assert.equal(typeof self.onmessage, 'function');

    const passphrase = utf8('password');
    const salt = utf8('somesalt');
    self.onmessage({
      data: {
        id: 1,
        op: 'derive',
        passphraseBytes: passphrase,
        saltBytes: salt,
        memoryKiB: 256,
        iterations: 2,
        parallelism: 1,
        hashLength: 32,
      },
    });
    assert.equal(posted.length, 1);
    assert.equal(posted[0].message.id, 1);
    assert.equal(posted[0].message.ok, true);
    assert.equal(
      toHex(posted[0].message.key),
      '9dfeb910e80bad0311fee20f9c0e2b12c17987b4cac90c2ef54d5b3021c68bfe',
    );
    assert.equal(posted[0].transfer[0], posted[0].message.key.buffer);
    // Worker zeroes the received passphrase buffer in finally.
    assert.deepEqual(Array.from(passphrase), Array(passphrase.length).fill(0));

    // Unknown op
    self.onmessage({ data: { id: 2, op: 'unknown' } });
    assert.equal(posted[1].message.ok, false);
    assert.match(posted[1].message.error, /Unknown op/);

    // Invalid parameter also zeroes passphrase buffer
    const badPass = utf8('secret-pass');
    self.onmessage({
      data: {
        id: 3,
        op: 'derive',
        passphraseBytes: badPass,
        saltBytes: utf8('somesalt'),
        memoryKiB: 4,
        iterations: 1,
        parallelism: 1,
        hashLength: 32,
      },
    });
    assert.equal(posted[2].message.ok, false);
    assert.match(posted[2].message.error, /Invalid memoryKiB/);
    assert.deepEqual(Array.from(badPass), Array(badPass.length).fill(0));
  });
});
