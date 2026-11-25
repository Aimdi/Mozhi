/*
 * Mozhi's backup KDF worker: RFC 9106 Argon2id (version 0x13) with
 * RFC 7693 BLAKE2b, pure vanilla JavaScript with zero dependencies.
 *
 * Uses Uint32Array (32-bit lo/hi pairs for 64-bit words) so V8,
 * SpiderMonkey and JavaScriptCore execute the compression loop without
 * BigInt allocations.
 *
 * Worker RPC protocol:
 *   page -> worker  {id, op: 'derive', passphraseBytes, saltBytes,
 *                    memoryKiB, iterations, parallelism, hashLength}
 *   worker -> page  {id, ok: true, key: Uint8Array} (buffer transferred)
 *                 | {id, ok: false, error: string}
 */
'use strict';

/* -------------------------------------------------------------------------- */
/* BLAKE2b (RFC 7693)                                                         */
/* -------------------------------------------------------------------------- */

const BLAKE2B_IV = new Uint32Array([
  0xf3bcc908, 0x6a09e667,
  0x84caa73b, 0xbb67ae85,
  0xfe94f82b, 0x3c6ef372,
  0x5f1d36f1, 0xa54ff53a,
  0xade682d1, 0x510e527f,
  0x2b3e6c1f, 0x9b05688c,
  0xfb41bd6b, 0x1f83d9ab,
  0x137e2179, 0x5be0cd19,
]);

const BLAKE2B_SIGMA = new Uint8Array([
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
  14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3,
  11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4,
  7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8,
  9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13,
  2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9,
  12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11,
  13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10,
  6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5,
  10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0,
]);

// Scratch buffers reused across BLAKE2b calls (single-threaded worker).
const _b2v = new Uint32Array(32);
const _b2m = new Uint32Array(32);
const _b2h = new Uint32Array(16);
const _b2Block = new Uint8Array(128);

function blake2bG(a, b, c, d, xLo, xHi, yLo, yHi) {
  const v = _b2v;
  const a2 = a << 1;
  const b2 = b << 1;
  const c2 = c << 1;
  const d2 = d << 1;

  let aLo = v[a2];
  let aHi = v[a2 + 1];
  let bLo = v[b2];
  let bHi = v[b2 + 1];
  let cLo = v[c2];
  let cHi = v[c2 + 1];
  let dLo = v[d2];
  let dHi = v[d2 + 1];

  // a = a + b + x
  let s1 = (aLo + bLo) >>> 0;
  let carry = s1 < aLo ? 1 : 0;
  let s2 = (s1 + xLo) >>> 0;
  carry += s2 < s1 ? 1 : 0;
  aLo = s2;
  aHi = (aHi + bHi + xHi + carry) >>> 0;

  // d = rotr64(d ^ a, 32)
  let tLo = dLo ^ aLo;
  let tHi = dHi ^ aHi;
  dLo = tHi;
  dHi = tLo;

  // c = c + d
  s1 = (cLo + dLo) >>> 0;
  cHi = (cHi + dHi + (s1 < cLo ? 1 : 0)) >>> 0;
  cLo = s1;

  // b = rotr64(b ^ c, 24)
  tLo = bLo ^ cLo;
  tHi = bHi ^ cHi;
  bLo = ((tLo >>> 24) | (tHi << 8)) >>> 0;
  bHi = ((tHi >>> 24) | (tLo << 8)) >>> 0;

  // a = a + b + y
  s1 = (aLo + bLo) >>> 0;
  carry = s1 < aLo ? 1 : 0;
  s2 = (s1 + yLo) >>> 0;
  carry += s2 < s1 ? 1 : 0;
  aLo = s2;
  aHi = (aHi + bHi + yHi + carry) >>> 0;

  // d = rotr64(d ^ a, 16)
  tLo = dLo ^ aLo;
  tHi = dHi ^ aHi;
  dLo = ((tLo >>> 16) | (tHi << 16)) >>> 0;
  dHi = ((tHi >>> 16) | (tLo << 16)) >>> 0;

  // c = c + d
  s1 = (cLo + dLo) >>> 0;
  cHi = (cHi + dHi + (s1 < cLo ? 1 : 0)) >>> 0;
  cLo = s1;

  // b = rotr64(b ^ c, 63) == rotl64(b ^ c, 1)
  tLo = bLo ^ cLo;
  tHi = bHi ^ cHi;
  bLo = ((tLo << 1) | (tHi >>> 31)) >>> 0;
  bHi = ((tHi << 1) | (tLo >>> 31)) >>> 0;

  v[a2] = aLo;
  v[a2 + 1] = aHi;
  v[b2] = bLo;
  v[b2 + 1] = bHi;
  v[c2] = cLo;
  v[c2 + 1] = cHi;
  v[d2] = dLo;
  v[d2 + 1] = dHi;
}

function blake2bCompress(h, block, tLo, tHi, isLast) {
  const v = _b2v;
  const m = _b2m;

  for (let i = 0; i < 16; i++) {
    v[i] = h[i];
    v[i + 16] = BLAKE2B_IV[i];
  }

  v[24] ^= tLo;
  v[25] ^= tHi;
  if (isLast) {
    v[28] = ~v[28];
    v[29] = ~v[29];
  }

  for (let i = 0; i < 32; i++) {
    const o = i << 2;
    m[i] =
      (block[o] |
        (block[o + 1] << 8) |
        (block[o + 2] << 16) |
        (block[o + 3] << 24)) >>>
      0;
  }

  for (let r = 0; r < 12; r++) {
    const s = (r % 10) * 16;
    let i0 = BLAKE2B_SIGMA[s] << 1;
    let i1 = BLAKE2B_SIGMA[s + 1] << 1;
    blake2bG(0, 4, 8, 12, m[i0], m[i0 + 1], m[i1], m[i1 + 1]);
    i0 = BLAKE2B_SIGMA[s + 2] << 1;
    i1 = BLAKE2B_SIGMA[s + 3] << 1;
    blake2bG(1, 5, 9, 13, m[i0], m[i0 + 1], m[i1], m[i1 + 1]);
    i0 = BLAKE2B_SIGMA[s + 4] << 1;
    i1 = BLAKE2B_SIGMA[s + 5] << 1;
    blake2bG(2, 6, 10, 14, m[i0], m[i0 + 1], m[i1], m[i1 + 1]);
    i0 = BLAKE2B_SIGMA[s + 6] << 1;
    i1 = BLAKE2B_SIGMA[s + 7] << 1;
    blake2bG(3, 7, 11, 15, m[i0], m[i0 + 1], m[i1], m[i1 + 1]);
    i0 = BLAKE2B_SIGMA[s + 8] << 1;
    i1 = BLAKE2B_SIGMA[s + 9] << 1;
    blake2bG(0, 5, 10, 15, m[i0], m[i0 + 1], m[i1], m[i1 + 1]);
    i0 = BLAKE2B_SIGMA[s + 10] << 1;
    i1 = BLAKE2B_SIGMA[s + 11] << 1;
    blake2bG(1, 6, 11, 12, m[i0], m[i0 + 1], m[i1], m[i1 + 1]);
    i0 = BLAKE2B_SIGMA[s + 12] << 1;
    i1 = BLAKE2B_SIGMA[s + 13] << 1;
    blake2bG(2, 7, 8, 13, m[i0], m[i0 + 1], m[i1], m[i1 + 1]);
    i0 = BLAKE2B_SIGMA[s + 14] << 1;
    i1 = BLAKE2B_SIGMA[s + 15] << 1;
    blake2bG(3, 4, 9, 14, m[i0], m[i0 + 1], m[i1], m[i1 + 1]);
  }

  for (let i = 0; i < 16; i++) {
    h[i] ^= v[i] ^ v[i + 16];
  }
}

/**
 * Unkeyed BLAKE2b digest of `input` (Uint8Array) producing `outLen` (1..64) bytes.
 */
function blake2b(input, outLen = 64) {
  if (outLen < 1 || outLen > 64) {
    throw new RangeError(`Invalid BLAKE2b output length: ${outLen}`);
  }
  const h = _b2h;
  for (let i = 0; i < 16; i++) h[i] = BLAKE2B_IV[i];
  h[0] ^= 0x01010000 ^ outLen;

  let offset = 0;
  let tLo = 0;
  let tHi = 0;
  const len = input.length;

  while (len - offset > 128) {
    const nextLo = (tLo + 128) >>> 0;
    if (nextLo < tLo) tHi = (tHi + 1) >>> 0;
    tLo = nextLo;
    blake2bCompress(h, input.subarray(offset, offset + 128), tLo, tHi, false);
    offset += 128;
  }

  const rem = len - offset;
  const nextLo = (tLo + rem) >>> 0;
  if (nextLo < tLo) tHi = (tHi + 1) >>> 0;
  tLo = nextLo;

  _b2Block.fill(0);
  if (rem > 0) _b2Block.set(input.subarray(offset), 0);
  blake2bCompress(h, _b2Block, tLo, tHi, true);

  const out = new Uint8Array(outLen);
  for (let i = 0; i < outLen; i++) {
    out[i] = (h[i >> 2] >>> ((i & 3) << 3)) & 0xff;
  }
  return out;
}

/* -------------------------------------------------------------------------- */
/* Argon2id (RFC 9106, version 0x13)                                          */
/* -------------------------------------------------------------------------- */

const ARGON2_ID = 2;
const ARGON2_VERSION = 0x13;
const SYNC_POINTS = 4;
const BLOCK_U32 = 256; // 1024 bytes = 128 uint64s = 256 uint32s

// Reusable scratch buffers for the block compression function G.
const _blockR = new Uint32Array(BLOCK_U32);
const _blockZ = new Uint32Array(BLOCK_U32);
const _zeroBlock = new Uint32Array(BLOCK_U32);
const _inputBlock = new Uint32Array(BLOCK_U32);
const _addrTmp = new Uint32Array(BLOCK_U32);
const _addrBlock = new Uint32Array(BLOCK_U32);

function writeU32LE(buf, offset, value) {
  buf[offset] = value & 0xff;
  buf[offset + 1] = (value >>> 8) & 0xff;
  buf[offset + 2] = (value >>> 16) & 0xff;
  buf[offset + 3] = (value >>> 24) & 0xff;
}

/**
 * Variable-length hash H'(tau, A) from RFC 9106 Section 3.3.
 */
function blake2bLong(input, outLen) {
  const framed = new Uint8Array(4 + input.length);
  writeU32LE(framed, 0, outLen >>> 0);
  framed.set(input, 4);

  try {
    if (outLen <= 64) {
      return blake2b(framed, outLen);
    }

    const out = new Uint8Array(outLen);
    let v = blake2b(framed, 64);
    out.set(v.subarray(0, 32), 0);

    let pos = 32;
    let remaining = outLen - 32;
    while (remaining > 64) {
      const next = blake2b(v, 64);
      v.fill(0);
      v = next;
      out.set(v.subarray(0, 32), pos);
      pos += 32;
      remaining -= 32;
    }

    const last = blake2b(v, remaining);
    v.fill(0);
    out.set(last, pos);
    last.fill(0);
    return out;
  } finally {
    framed.fill(0);
  }
}

/**
 * Exact upper 32 bits of (a * b) where a, b are unsigned 32-bit integers.
 */
function mulHi32(a, b) {
  const aL = a & 0xffff;
  const aH = a >>> 16;
  const bL = b & 0xffff;
  const bH = b >>> 16;
  const ll = Math.imul(aL, bL) >>> 0;
  const lh = Math.imul(aL, bH) >>> 0;
  const hl = Math.imul(aH, bL) >>> 0;
  const hh = Math.imul(aH, bH) >>> 0;
  const mid = (ll >>> 16) + (lh & 0xffff) + (hl & 0xffff);
  return (hh + (lh >>> 16) + (hl >>> 16) + (mid >>> 16)) >>> 0;
}

/**
 * Argon2's modified BLAKE2b round function GB(a, b, c, d) on 64-bit words
 * stored as (lo, hi) Uint32 pairs inside `z` at Uint32 indices a, b, c, d.
 */
function argon2GB(z, a, b, c, d) {
  let aLo = z[a];
  let aHi = z[a + 1];
  let bLo = z[b];
  let bHi = z[b + 1];
  let cLo = z[c];
  let cHi = z[c + 1];
  let dLo = z[d];
  let dHi = z[d + 1];

  // 1. a = a + b + 2 * lo32(a) * lo32(b)
  {
    const xL = aLo & 0xffff;
    const xH = aLo >>> 16;
    const yL = bLo & 0xffff;
    const yH = bLo >>> 16;
    const ll = Math.imul(xL, yL) >>> 0;
    const lh = Math.imul(xL, yH) >>> 0;
    const hl = Math.imul(xH, yL) >>> 0;
    const hh = Math.imul(xH, yH) >>> 0;
    const mid = (ll >>> 16) + (lh & 0xffff) + (hl & 0xffff);
    const pLo = (((mid & 0xffff) << 16) | (ll & 0xffff)) >>> 0;
    const pHi = (hh + (lh >>> 16) + (hl >>> 16) + (mid >>> 16)) >>> 0;
    const tLo = (pLo << 1) >>> 0;
    const tHi = ((pHi << 1) | (pLo >>> 31)) >>> 0;

    const s1 = (aLo + bLo) >>> 0;
    let carry = s1 < aLo ? 1 : 0;
    const s2 = (s1 + tLo) >>> 0;
    carry += s2 < s1 ? 1 : 0;
    aLo = s2;
    aHi = (aHi + bHi + tHi + carry) >>> 0;
  }

  // d = rotr64(d ^ a, 32)
  {
    const tLo = dLo ^ aLo;
    const tHi = dHi ^ aHi;
    dLo = tHi;
    dHi = tLo;
  }

  // 2. c = c + d + 2 * lo32(c) * lo32(d)
  {
    const xL = cLo & 0xffff;
    const xH = cLo >>> 16;
    const yL = dLo & 0xffff;
    const yH = dLo >>> 16;
    const ll = Math.imul(xL, yL) >>> 0;
    const lh = Math.imul(xL, yH) >>> 0;
    const hl = Math.imul(xH, yL) >>> 0;
    const hh = Math.imul(xH, yH) >>> 0;
    const mid = (ll >>> 16) + (lh & 0xffff) + (hl & 0xffff);
    const pLo = (((mid & 0xffff) << 16) | (ll & 0xffff)) >>> 0;
    const pHi = (hh + (lh >>> 16) + (hl >>> 16) + (mid >>> 16)) >>> 0;
    const tLo = (pLo << 1) >>> 0;
    const tHi = ((pHi << 1) | (pLo >>> 31)) >>> 0;

    const s1 = (cLo + dLo) >>> 0;
    let carry = s1 < cLo ? 1 : 0;
    const s2 = (s1 + tLo) >>> 0;
    carry += s2 < s1 ? 1 : 0;
    cLo = s2;
    cHi = (cHi + dHi + tHi + carry) >>> 0;
  }

  // b = rotr64(b ^ c, 24)
  {
    const tLo = bLo ^ cLo;
    const tHi = bHi ^ cHi;
    bLo = ((tLo >>> 24) | (tHi << 8)) >>> 0;
    bHi = ((tHi >>> 24) | (tLo << 8)) >>> 0;
  }

  // 3. a = a + b + 2 * lo32(a) * lo32(b)
  {
    const xL = aLo & 0xffff;
    const xH = aLo >>> 16;
    const yL = bLo & 0xffff;
    const yH = bLo >>> 16;
    const ll = Math.imul(xL, yL) >>> 0;
    const lh = Math.imul(xL, yH) >>> 0;
    const hl = Math.imul(xH, yL) >>> 0;
    const hh = Math.imul(xH, yH) >>> 0;
    const mid = (ll >>> 16) + (lh & 0xffff) + (hl & 0xffff);
    const pLo = (((mid & 0xffff) << 16) | (ll & 0xffff)) >>> 0;
    const pHi = (hh + (lh >>> 16) + (hl >>> 16) + (mid >>> 16)) >>> 0;
    const tLo = (pLo << 1) >>> 0;
    const tHi = ((pHi << 1) | (pLo >>> 31)) >>> 0;

    const s1 = (aLo + bLo) >>> 0;
    let carry = s1 < aLo ? 1 : 0;
    const s2 = (s1 + tLo) >>> 0;
    carry += s2 < s1 ? 1 : 0;
    aLo = s2;
    aHi = (aHi + bHi + tHi + carry) >>> 0;
  }

  // d = rotr64(d ^ a, 16)
  {
    const tLo = dLo ^ aLo;
    const tHi = dHi ^ aHi;
    dLo = ((tLo >>> 16) | (tHi << 16)) >>> 0;
    dHi = ((tHi >>> 16) | (tLo << 16)) >>> 0;
  }

  // 4. c = c + d + 2 * lo32(c) * lo32(d)
  {
    const xL = cLo & 0xffff;
    const xH = cLo >>> 16;
    const yL = dLo & 0xffff;
    const yH = dLo >>> 16;
    const ll = Math.imul(xL, yL) >>> 0;
    const lh = Math.imul(xL, yH) >>> 0;
    const hl = Math.imul(xH, yL) >>> 0;
    const hh = Math.imul(xH, yH) >>> 0;
    const mid = (ll >>> 16) + (lh & 0xffff) + (hl & 0xffff);
    const pLo = (((mid & 0xffff) << 16) | (ll & 0xffff)) >>> 0;
    const pHi = (hh + (lh >>> 16) + (hl >>> 16) + (mid >>> 16)) >>> 0;
    const tLo = (pLo << 1) >>> 0;
    const tHi = ((pHi << 1) | (pLo >>> 31)) >>> 0;

    const s1 = (cLo + dLo) >>> 0;
    let carry = s1 < cLo ? 1 : 0;
    const s2 = (s1 + tLo) >>> 0;
    carry += s2 < s1 ? 1 : 0;
    cLo = s2;
    cHi = (cHi + dHi + tHi + carry) >>> 0;
  }

  // b = rotr64(b ^ c, 63) == rotl64(b ^ c, 1)
  {
    const tLo = bLo ^ cLo;
    const tHi = bHi ^ cHi;
    bLo = ((tLo << 1) | (tHi >>> 31)) >>> 0;
    bHi = ((tHi << 1) | (tLo >>> 31)) >>> 0;
  }

  z[a] = aLo;
  z[a + 1] = aHi;
  z[b] = bLo;
  z[b + 1] = bHi;
  z[c] = cLo;
  z[c + 1] = cHi;
  z[d] = dLo;
  z[d + 1] = dHi;
}

/**
 * Permutation P over 16 64-bit words at Uint32 offsets i0..i15 inside `z`.
 */
function blake2bRound(
  z,
  i0, i1, i2, i3,
  i4, i5, i6, i7,
  i8, i9, i10, i11,
  i12, i13, i14, i15,
) {
  argon2GB(z, i0, i4, i8, i12);
  argon2GB(z, i1, i5, i9, i13);
  argon2GB(z, i2, i6, i10, i14);
  argon2GB(z, i3, i7, i11, i15);

  argon2GB(z, i0, i5, i10, i15);
  argon2GB(z, i1, i6, i11, i12);
  argon2GB(z, i2, i7, i8, i13);
  argon2GB(z, i3, i4, i9, i14);
}

/**
 * Compression function G(X, Y) from RFC 9106 Section 3.5.
 * Reads X from `xBuf[xOff..xOff+255]` and Y from `yBuf[yOff..yOff+255]`,
 * and writes (or XORs when `xorOut` is true) into `outBuf[outOff..outOff+255]`.
 */
function compressBlock(xBuf, xOff, yBuf, yOff, outBuf, outOff, xorOut) {
  const r = _blockR;
  const z = _blockZ;

  for (let i = 0; i < BLOCK_U32; i++) {
    const v = (xBuf[xOff + i] ^ yBuf[yOff + i]) >>> 0;
    r[i] = v;
    z[i] = v;
  }

  // Row-wise P over 8 rows of 16 64-bit words (32 Uint32s per row).
  for (let row = 0; row < 8; row++) {
    const b = row << 5;
    blake2bRound(
      z,
      b, b + 2, b + 4, b + 6,
      b + 8, b + 10, b + 12, b + 14,
      b + 16, b + 18, b + 20, b + 22,
      b + 24, b + 26, b + 28, b + 30,
    );
  }

  // Column-wise P over 8 columns (2 consecutive 64-bit words per row).
  for (let col = 0; col < 8; col++) {
    const c = col << 2;
    blake2bRound(
      z,
      c, c + 2, c + 32, c + 34,
      c + 64, c + 66, c + 96, c + 98,
      c + 128, c + 130, c + 160, c + 162,
      c + 192, c + 194, c + 224, c + 226,
    );
  }

  if (xorOut) {
    for (let i = 0; i < BLOCK_U32; i++) {
      outBuf[outOff + i] = (outBuf[outOff + i] ^ r[i] ^ z[i]) >>> 0;
    }
  } else {
    for (let i = 0; i < BLOCK_U32; i++) {
      outBuf[outOff + i] = (r[i] ^ z[i]) >>> 0;
    }
  }
}

function nextAddresses(pass, lane, slice, memoryBlocks, iterations, counter) {
  _inputBlock.fill(0);
  _inputBlock[0] = pass >>> 0;
  _inputBlock[2] = lane >>> 0;
  _inputBlock[4] = slice >>> 0;
  _inputBlock[6] = memoryBlocks >>> 0;
  _inputBlock[8] = iterations >>> 0;
  _inputBlock[10] = ARGON2_ID;
  _inputBlock[12] = counter >>> 0;

  compressBlock(_zeroBlock, 0, _inputBlock, 0, _addrTmp, 0, false);
  compressBlock(_zeroBlock, 0, _addrTmp, 0, _addrBlock, 0, false);
}

/**
 * Computes RFC 9106 Argon2id (version 0x13).
 *
 * @param {object} params
 * @param {Uint8Array} params.passphraseBytes
 * @param {Uint8Array} params.saltBytes
 * @param {number} params.memoryKiB
 * @param {number} params.iterations
 * @param {number} params.parallelism
 * @param {number} params.hashLength
 * @param {Uint8Array} [params.secret]
 * @param {Uint8Array} [params.associatedData]
 * @returns {Uint8Array}
 */
function argon2id({
  passphraseBytes,
  saltBytes,
  memoryKiB,
  iterations,
  parallelism,
  hashLength,
  secret = new Uint8Array(0),
  associatedData = new Uint8Array(0),
}) {
  const P = toUint8Array(passphraseBytes);
  const S = toUint8Array(saltBytes);
  const K = toUint8Array(secret);
  const X = toUint8Array(associatedData);

  let initBuf = null;
  let h0 = null;
  let memory = null;
  let blockSeed = null;
  let finalWords = null;
  let finalBlock = null;

  try {
    if (!Number.isInteger(parallelism) || parallelism < 1) {
      throw new RangeError(`Invalid parallelism: ${parallelism}`);
    }
    if (!Number.isInteger(iterations) || iterations < 1) {
      throw new RangeError(`Invalid iterations: ${iterations}`);
    }
    if (!Number.isInteger(memoryKiB) || memoryKiB < 8 * parallelism) {
      throw new RangeError(`Invalid memoryKiB: ${memoryKiB}`);
    }
    if (!Number.isInteger(hashLength) || hashLength < 4) {
      throw new RangeError(`Invalid hashLength: ${hashLength}`);
    }

    // Step 1: H_0 = BLAKE2b-512(LE32(p) || LE32(T) || LE32(m) || LE32(t) ||
    //                           LE32(v) || LE32(y) || len||P || len||S ||
    //                           len||K || len||X)
    const initLen = 40 + P.length + S.length + K.length + X.length;
    initBuf = new Uint8Array(initLen);
    let off = 0;
    writeU32LE(initBuf, off, parallelism); off += 4;
    writeU32LE(initBuf, off, hashLength); off += 4;
    writeU32LE(initBuf, off, memoryKiB); off += 4;
    writeU32LE(initBuf, off, iterations); off += 4;
    writeU32LE(initBuf, off, ARGON2_VERSION); off += 4;
    writeU32LE(initBuf, off, ARGON2_ID); off += 4;
    writeU32LE(initBuf, off, P.length); off += 4;
    initBuf.set(P, off); off += P.length;
    writeU32LE(initBuf, off, S.length); off += 4;
    initBuf.set(S, off); off += S.length;
    writeU32LE(initBuf, off, K.length); off += 4;
    initBuf.set(K, off); off += K.length;
    writeU32LE(initBuf, off, X.length); off += 4;
    initBuf.set(X, off);

    h0 = blake2b(initBuf, 64);

    // Step 2: Memory layout (m' blocks, laneLength blocks per lane).
    const segmentLength = Math.floor(memoryKiB / (SYNC_POINTS * parallelism));
    const laneLength = segmentLength * SYNC_POINTS;
    const memoryBlocks = laneLength * parallelism;
    memory = new Uint32Array(memoryBlocks * BLOCK_U32);

    // Step 3: Initial blocks B[i][0] and B[i][1] for every lane.
    blockSeed = new Uint8Array(72);
    blockSeed.set(h0, 0);
    for (let lane = 0; lane < parallelism; lane++) {
      writeU32LE(blockSeed, 68, lane);
      for (let j = 0; j < 2; j++) {
        writeU32LE(blockSeed, 64, j);
        const blockBytes = blake2bLong(blockSeed, 1024);
        const dstOff = (lane * laneLength + j) * BLOCK_U32;
        for (let w = 0; w < BLOCK_U32; w++) {
          const bo = w << 2;
          memory[dstOff + w] =
            (blockBytes[bo] |
              (blockBytes[bo + 1] << 8) |
              (blockBytes[bo + 2] << 16) |
              (blockBytes[bo + 3] << 24)) >>>
            0;
        }
        blockBytes.fill(0);
      }
    }

    // Step 4: Fill memory over `iterations` passes × 4 sync points × `parallelism` lanes.
    for (let pass = 0; pass < iterations; pass++) {
      for (let slice = 0; slice < SYNC_POINTS; slice++) {
        const dataIndependent = pass === 0 && slice < 2;

        for (let lane = 0; lane < parallelism; lane++) {
          let addrCounter = 0;
          const startIdx = pass === 0 && slice === 0 ? 2 : 0;

          if (dataIndependent && startIdx > 0) {
            addrCounter = 1;
            nextAddresses(pass, lane, slice, memoryBlocks, iterations, addrCounter);
          }

          for (let index = startIdx; index < segmentLength; index++) {
            const currPos = slice * segmentLength + index;
            const currOffset = (lane * laneLength + currPos) * BLOCK_U32;
            const prevPos = currPos === 0 ? laneLength - 1 : currPos - 1;
            const prevOffset = (lane * laneLength + prevPos) * BLOCK_U32;

            let j1;
            let j2;
            if (dataIndependent) {
              const addrSlot = index & 127;
              if (addrSlot === 0) {
                addrCounter++;
                nextAddresses(pass, lane, slice, memoryBlocks, iterations, addrCounter);
              }
              j1 = _addrBlock[addrSlot << 1];
              j2 = _addrBlock[(addrSlot << 1) + 1];
            } else {
              j1 = memory[prevOffset];
              j2 = memory[prevOffset + 1];
            }

            const refLane =
              pass === 0 && slice === 0 ? lane : j2 % parallelism;

            let refAreaSize;
            if (pass === 0) {
              if (slice === 0) {
                refAreaSize = index - 1;
              } else if (refLane === lane) {
                refAreaSize = slice * segmentLength + index - 1;
              } else {
                refAreaSize = slice * segmentLength + (index === 0 ? -1 : 0);
              }
            } else if (refLane === lane) {
              refAreaSize = laneLength - segmentLength + index - 1;
            } else {
              refAreaSize = laneLength - segmentLength + (index === 0 ? -1 : 0);
            }

            const x = mulHi32(j1, j1);
            const y = mulHi32(refAreaSize >>> 0, x);
            const relativePos = refAreaSize - 1 - y;

            const startPos =
              pass !== 0 && slice !== SYNC_POINTS - 1
                ? (slice + 1) * segmentLength
                : 0;
            const refIndex = (startPos + relativePos) % laneLength;
            const refOffset = (refLane * laneLength + refIndex) * BLOCK_U32;

            compressBlock(
              memory,
              prevOffset,
              memory,
              refOffset,
              memory,
              currOffset,
              pass !== 0,
            );
          }
        }
      }
    }

    // Step 5: Finalize C = B[0][q-1] XOR B[1][q-1] XOR ... XOR B[p-1][q-1].
    finalWords = new Uint32Array(BLOCK_U32);
    for (let lane = 0; lane < parallelism; lane++) {
      const lastOff = (lane * laneLength + laneLength - 1) * BLOCK_U32;
      for (let i = 0; i < BLOCK_U32; i++) {
        finalWords[i] = (finalWords[i] ^ memory[lastOff + i]) >>> 0;
      }
    }

    finalBlock = new Uint8Array(1024);
    for (let i = 0; i < BLOCK_U32; i++) {
      writeU32LE(finalBlock, i << 2, finalWords[i]);
    }

    return blake2bLong(finalBlock, hashLength);
  } finally {
    P.fill(0);
    K.fill(0);
    if (initBuf) initBuf.fill(0);
    if (h0) h0.fill(0);
    if (blockSeed) blockSeed.fill(0);
    if (memory) memory.fill(0);
    if (finalWords) finalWords.fill(0);
    if (finalBlock) finalBlock.fill(0);
    _b2v.fill(0);
    _b2m.fill(0);
    _b2h.fill(0);
    _b2Block.fill(0);
    _blockR.fill(0);
    _blockZ.fill(0);
    _inputBlock.fill(0);
    _addrTmp.fill(0);
    _addrBlock.fill(0);
  }
}

function toUint8Array(value) {
  if (value instanceof Uint8Array) return value;
  if (ArrayBuffer.isView(value)) {
    return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
  }
  if (value instanceof ArrayBuffer) return new Uint8Array(value);
  if (Array.isArray(value)) return Uint8Array.from(value);
  throw new TypeError('Expected Uint8Array or byte array');
}

/* -------------------------------------------------------------------------- */
/* Web Worker RPC & Node.js test hook                                         */
/* -------------------------------------------------------------------------- */

if (typeof self !== 'undefined' && typeof self.postMessage === 'function') {
  self.onmessage = (event) => {
    const message = event.data;
    const id = message && message.id;
    try {
      if (!message || message.op !== 'derive') {
        throw new Error(`Unknown op ${message && message.op}`);
      }
      const key = argon2id({
        passphraseBytes: message.passphraseBytes,
        saltBytes: message.saltBytes,
        memoryKiB: message.memoryKiB,
        iterations: message.iterations,
        parallelism: message.parallelism,
        hashLength: message.hashLength,
      });
      self.postMessage({ id, ok: true, key }, [key.buffer]);
    } catch (error) {
      self.postMessage({
        id,
        ok: false,
        error: String((error && error.message) || error),
      });
    }
  };
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = { argon2id, blake2b };
} else if (typeof globalThis !== 'undefined') {
  globalThis.__mozhiArgon2 = { argon2id, blake2b };
}
