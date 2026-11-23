#!/usr/bin/env node
// Verifies web/backup/argon2_worker.js (BLAKE2b, RFC 9106 Argon2id v0x13,
// Web Worker RPC protocol, and exact byte-for-byte parity with Dart's
// DartArgon2id vectors).
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const __dirname = dirname(fileURLToPath(import.meta.url));
const workerPath = resolve(__dirname, '../web/backup/argon2_worker.js');
const workerSource = readFileSync(workerPath, 'utf8');

function toHex(bytes) {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
}

function utf8(text) {
  return new TextEncoder().encode(text);
}

// 1. Load directly via CommonJS-like sandbox to test exported functions.
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
  vm.runInNewContext(workerSource, context, { filename: workerPath });
  return mod.exports;
}

// 2. Load inside a simulated Web Worker environment (`self.postMessage`).
function loadAsWorker() {
  const posted = [];
  const selfObj = {
    onmessage: null,
    postMessage(message, transfer) {
      posted.push({ message, transfer });
    },
  };
  const context = {
    self: selfObj,
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
  vm.runInNewContext(workerSource, context, { filename: workerPath });
  return { self: selfObj, posted };
}

const { argon2id, blake2b } = loadDirect();

// --- BLAKE2b RFC 7693 sanity checks ---
assert.equal(
  toHex(blake2b(utf8(''), 64)),
  '786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419' +
    'd25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce',
  'BLAKE2b-512("")',
);
assert.equal(
  toHex(blake2b(utf8('abc'), 64)),
  'ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d1' +
    '7d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923',
  'BLAKE2b-512("abc")',
);

// --- RFC 9106 Section 5.3 official Argon2id test vector ---
// p=4, T=32, m=32, t=3, v=0x13, P=0x01*32, S=0x02*16, K=0x03*8, X=0x04*12
{
  const digest = argon2id({
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
    toHex(digest),
    '0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659',
    'RFC 9106 Section 5.3 Argon2id official vector',
  );
}

// --- Reference vector also asserted in test/backup/data/backup_codec_test.dart ---
{
  const digest = argon2id({
    passphraseBytes: utf8('password'),
    saltBytes: utf8('somesalt'),
    memoryKiB: 256,
    iterations: 2,
    parallelism: 1,
    hashLength: 32,
  });
  assert.equal(
    toHex(digest),
    '9dfeb910e80bad0311fee20f9c0e2b12c17987b4cac90c2ef54d5b3021c68bfe',
    'Reference Argon2id vector (t=2, m=256, p=1)',
  );
}

// --- Cross-check vectors shared with Dart's DartArgon2id ---
// The exact same vectors are asserted in test/backup/data/backup_codec_test.dart.
const crossCheckVectors = [
  {
    label: '64 KiB, t=1, p=1, ASCII passphrase',
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
    label: '1024 KiB, t=3, p=2, UTF-8 NFC passphrase (Tamil + Vietnamese + emoji)',
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
    label: '19456 KiB (BackupKdf.browser), t=2, p=1, empty passphrase',
    passphrase: '',
    salt: 'browser-kdf-salt',
    memoryKiB: 19456,
    iterations: 2,
    parallelism: 1,
    hashLength: 32,
    expected:
      'feccd24fc733108fdbe26c1d13fe543d0e8a241fc69125b2a5d6b774ca9ede25',
  },
  {
    label: '128 KiB, t=2, p=4 (max parallelism), 64-byte tag',
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

for (const vec of crossCheckVectors) {
  const started = Date.now();
  const actual = toHex(
    argon2id({
      passphraseBytes: utf8(vec.passphrase),
      saltBytes: utf8(vec.salt),
      memoryKiB: vec.memoryKiB,
      iterations: vec.iterations,
      parallelism: vec.parallelism,
      hashLength: vec.hashLength,
    }),
  );
  const elapsedMs = Date.now() - started;
  assert.equal(actual, vec.expected, vec.label);
  console.log(`  ok [${elapsedMs}ms] ${vec.label}`);
}

// --- Web Worker RPC protocol test ---
{
  const { self, posted } = loadAsWorker();
  assert.equal(typeof self.onmessage, 'function', 'Worker registers onmessage');

  // Valid derive request
  self.onmessage({
    data: {
      id: 42,
      op: 'derive',
      passphraseBytes: utf8('password'),
      saltBytes: utf8('somesalt'),
      memoryKiB: 256,
      iterations: 2,
      parallelism: 1,
      hashLength: 32,
    },
  });
  assert.equal(posted.length, 1);
  assert.equal(posted[0].message.id, 42);
  assert.equal(posted[0].message.ok, true);
  assert.ok(posted[0].message.key instanceof Uint8Array);
  assert.equal(
    toHex(posted[0].message.key),
    '9dfeb910e80bad0311fee20f9c0e2b12c17987b4cac90c2ef54d5b3021c68bfe',
  );
  assert.equal(posted[0].transfer.length, 1);
  assert.equal(posted[0].transfer[0], posted[0].message.key.buffer);

  // Unknown op error response
  self.onmessage({ data: { id: 43, op: 'bogus' } });
  assert.equal(posted.length, 2);
  assert.equal(posted[1].message.id, 43);
  assert.equal(posted[1].message.ok, false);
  assert.match(posted[1].message.error, /Unknown op/);

  // Invalid parameter error response
  self.onmessage({
    data: {
      id: 44,
      op: 'derive',
      passphraseBytes: utf8('password'),
      saltBytes: utf8('somesalt'),
      memoryKiB: 4,
      iterations: 1,
      parallelism: 1,
      hashLength: 32,
    },
  });
  assert.equal(posted.length, 3);
  assert.equal(posted[2].message.id, 44);
  assert.equal(posted[2].message.ok, false);
  assert.match(posted[2].message.error, /Invalid memoryKiB/);
}

console.log('All Argon2id worker tests passed!');
