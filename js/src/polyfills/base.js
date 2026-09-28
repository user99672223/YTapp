// console, timers, queueMicrotask, performance, crypto, structuredClone, reportError.
import { nativeFn } from './native.js';
import { utf8Encode } from './encoding.js';

// ---------------------------------------------------------------- console

function formatArg(arg) {
  if (typeof arg === 'string') return arg;
  if (arg instanceof Error) return `${arg.name}: ${arg.message}${arg.stack ? `\n${arg.stack}` : ''}`;
  if (arg === undefined) return 'undefined';
  if (typeof arg === 'function') return `[Function ${arg.name || 'anonymous'}]`;
  try {
    const seen = new WeakSet();
    const json = JSON.stringify(arg, (key, value) => {
      if (typeof value === 'object' && value !== null) {
        if (seen.has(value)) return '[Circular]';
        seen.add(value);
      }
      if (typeof value === 'bigint') return value.toString();
      return value;
    });
    return json && json.length > 4000 ? json.slice(0, 4000) + '…' : String(json);
  } catch {
    return String(arg);
  }
}

export function makeConsole() {
  const log = nativeFn('log');
  const emit = (level) => (...args) => {
    const message = args.map(formatArg).join(' ');
    if (log) log(level, message);
  };
  return {
    log: emit('log'),
    info: emit('info'),
    warn: emit('warn'),
    error: emit('error'),
    debug: emit('debug'),
    trace: emit('debug'),
    group() {},
    groupCollapsed() {},
    groupEnd() {},
    time() {},
    timeEnd() {},
    assert(cond, ...args) {
      if (!cond) emit('error')('Assertion failed', ...args);
    },
    table: emit('log'),
    dir: emit('log')
  };
}

export function reportError(error) {
  const log = nativeFn('log');
  if (log) log('error', `Uncaught ${formatArg(error)}`);
}

// ---------------------------------------------------------------- timers

let timerSeq = 0;
const timers = new Map();

globalThis.__tubeTimerFire = function (id) {
  const timer = timers.get(id);
  if (!timer) return;
  if (timer.interval) {
    const setTimer = nativeFn('setTimer');
    if (setTimer) setTimer(id, timer.delay);
  } else {
    timers.delete(id);
  }
  try {
    timer.fn(...timer.args);
  } catch (e) {
    reportError(e);
  }
};

function startTimer(fn, delay, args, interval) {
  if (typeof fn !== 'function') {
    const code = String(fn);
    fn = () => (0, eval)(code);
  }
  const id = ++timerSeq;
  const ms = Math.max(0, Number(delay) || 0);
  timers.set(id, { fn, args, interval, delay: interval ? Math.max(ms, 1) : ms });
  const setTimer = nativeFn('setTimer');
  if (setTimer) {
    setTimer(id, interval ? Math.max(ms, 1) : ms);
  } else {
    // Bare context (tests without a host): run on the microtask queue, ignoring the delay.
    Promise.resolve().then(() => globalThis.__tubeTimerFire(id));
  }
  return id;
}

function stopTimer(id) {
  if (!timers.has(id)) return;
  timers.delete(id);
  const clearTimer = nativeFn('clearTimer');
  if (clearTimer) clearTimer(id);
}

export const setTimeout = (fn, delay, ...args) => startTimer(fn, delay, args, false);
export const setInterval = (fn, delay, ...args) => startTimer(fn, delay, args, true);
export const clearTimeout = (id) => stopTimer(id);
export const clearInterval = (id) => stopTimer(id);
export const setImmediate = (fn, ...args) => startTimer(fn, 0, args, false);
export const clearImmediate = (id) => stopTimer(id);

export function queueMicrotask(fn) {
  Promise.resolve().then(fn).catch(reportError);
}

// ---------------------------------------------------------------- performance

const startMs = Date.now();
export const performance = {
  timeOrigin: startMs,
  now() {
    const now = nativeFn('now');
    return now ? now() : Date.now() - startMs;
  },
  mark() {},
  measure() {},
  getEntriesByName() {
    return [];
  },
  toJSON() {
    return { timeOrigin: startMs };
  }
};

// ---------------------------------------------------------------- crypto

function randomBytes(length) {
  const nativeRandom = nativeFn('randomBytes');
  if (nativeRandom) {
    const bytes = nativeRandom(length);
    if (bytes && bytes.length === length) return bytes;
  }
  const out = new Uint8Array(length);
  for (let i = 0; i < length; i++) out[i] = Math.floor(Math.random() * 256);
  return out;
}

export const crypto = {
  getRandomValues(array) {
    if (!ArrayBuffer.isView(array)) throw new TypeError('Expected an integer TypedArray');
    if (array.byteLength > 65536) throw new Error('QuotaExceededError');
    const bytes = randomBytes(array.byteLength);
    new Uint8Array(array.buffer, array.byteOffset, array.byteLength).set(bytes);
    return array;
  },
  randomUUID() {
    const b = randomBytes(16);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    const hex = Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  }
};

// SHA-1 (hex) for SAPISIDHASH. Native CommonCrypto when available.
export function sha1Hex(message) {
  const nativeSha1 = nativeFn('sha1Hex');
  if (nativeSha1) {
    const out = nativeSha1(String(message));
    if (typeof out === 'string' && out.length === 40) return out;
  }
  const bytes = utf8Encode(String(message));
  const bitLength = bytes.length * 8;
  const paddedLength = (((bytes.length + 8) >> 6) + 1) << 6;
  const data = new Uint8Array(paddedLength);
  data.set(bytes);
  data[bytes.length] = 0x80;
  const view = new DataView(data.buffer);
  view.setUint32(paddedLength - 4, bitLength >>> 0);
  view.setUint32(paddedLength - 8, Math.floor(bitLength / 0x100000000));
  let h0 = 0x67452301, h1 = 0xefcdab89, h2 = 0x98badcfe, h3 = 0x10325476, h4 = 0xc3d2e1f0;
  const w = new Uint32Array(80);
  for (let offset = 0; offset < paddedLength; offset += 64) {
    for (let i = 0; i < 16; i++) w[i] = view.getUint32(offset + i * 4);
    for (let i = 16; i < 80; i++) {
      const x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16];
      w[i] = (x << 1) | (x >>> 31);
    }
    let a = h0, b = h1, c = h2, d = h3, e = h4;
    for (let i = 0; i < 80; i++) {
      let f, k;
      if (i < 20) {
        f = (b & c) | (~b & d);
        k = 0x5a827999;
      } else if (i < 40) {
        f = b ^ c ^ d;
        k = 0x6ed9eba1;
      } else if (i < 60) {
        f = (b & c) | (b & d) | (c & d);
        k = 0x8f1bbcdc;
      } else {
        f = b ^ c ^ d;
        k = 0xca62c1d6;
      }
      const temp = (((a << 5) | (a >>> 27)) + f + e + k + w[i]) >>> 0;
      e = d;
      d = c;
      c = (b << 30) | (b >>> 2);
      b = a;
      a = temp;
    }
    h0 = (h0 + a) >>> 0;
    h1 = (h1 + b) >>> 0;
    h2 = (h2 + c) >>> 0;
    h3 = (h3 + d) >>> 0;
    h4 = (h4 + e) >>> 0;
  }
  return [h0, h1, h2, h3, h4].map((h) => (h >>> 0).toString(16).padStart(8, '0')).join('');
}

export function structuredClone(value) {
  if (value === undefined) return undefined;
  return JSON.parse(JSON.stringify(value));
}
