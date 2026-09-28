// YouTube.js platform shim for JavaScriptCore: native file cache, SHA-1, UUIDs, fetch and the
// JavaScript evaluator used to run the extracted signature / n-parameter decipher code.
import { Platform, Log } from 'youtubei.js/web';
import { nativeFn } from '../polyfills/native.js';
import { sha1Hex } from '../polyfills/base.js';
import { toUint8Array, exactBytes } from '../polyfills/encoding.js';

// ICache backed by files in the app's Caches directory (see JSRuntime.swift).
export class NativeCache {
  constructor(persistent = true, persistentDirectory) {
    this._dir = persistentDirectory || 'youtubei';
    this._memory = new Map();
    this._persistent = persistent;
  }

  get cache_dir() {
    return this._dir;
  }

  async get(key) {
    const k = String(key);
    const getter = nativeFn('cacheGet');
    if (getter) {
      const bytes = getter(k);
      if (bytes == null) return undefined;
      const u8 = toUint8Array(bytes);
      return u8.buffer.slice(u8.byteOffset, u8.byteOffset + u8.byteLength);
    }
    return this._memory.get(k);
  }

  async set(key, value) {
    const k = String(key);
    const setter = nativeFn('cacheSet');
    const u8 = exactBytes(new Uint8Array(toUint8Array(value)));
    if (setter) setter(k, u8);
    else this._memory.set(k, u8.buffer);
  }

  async remove(key) {
    const k = String(key);
    const remover = nativeFn('cacheRemove');
    if (remover) remover(k);
    this._memory.delete(k);
  }
}

// The decipher script YouTube.js builds is `<extracted player code>\nfunction process(...){...}\n
// return process("n", "sp", "s");`. Compiling ~100 KB of code for every URL is slow without a
// JIT, so the part before the final call is compiled once and reused with real arguments.
const compiled = new Map();
const MAX_COMPILED = 4;

export function evaluate(data, env) {
  const code = data && typeof data.output === 'string' ? data.output : String(data);
  const marker = '\nreturn process(';
  const cut = code.lastIndexOf(marker);
  if (cut > 0 && code.indexOf('function process(') !== -1) {
    const head = code.slice(0, cut);
    let fn = compiled.get(head);
    if (!fn) {
      // eslint-disable-next-line no-new-func
      fn = new Function('__tube_n', '__tube_sp', '__tube_s', `${head}\nreturn process(__tube_n, __tube_sp, __tube_s);`);
      compiled.set(head, fn);
      if (compiled.size > MAX_COMPILED) compiled.delete(compiled.keys().next().value);
    }
    const e = env || {};
    return fn(e.n || '', e.sp || '', e.sig || '');
  }
  // eslint-disable-next-line no-new-func
  return new Function(code)();
}

let loaded = false;

export function loadPlatform() {
  if (loaded) return;
  loaded = true;
  Platform.load({
    runtime: 'unknown',
    // We are a native client (URLSession), so YouTube.js may set User-Agent / Origin headers.
    server: true,
    Cache: NativeCache,
    sha1Hash: async (data) => sha1Hex(data),
    uuidv4: () => globalThis.crypto.randomUUID(),
    eval: evaluate,
    fetch: (input, init) => globalThis.fetch(input, init),
    Request: globalThis.Request,
    Response: globalThis.Response,
    Headers: globalThis.Headers,
    FormData: globalThis.FormData,
    File: globalThis.File,
    ReadableStream: globalThis.ReadableStream,
    CustomEvent: globalThis.CustomEvent
  });
  Log.setLevel(Log.Level.WARNING, Log.Level.ERROR);
}
