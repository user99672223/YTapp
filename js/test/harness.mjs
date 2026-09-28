// Loads the bundle into a bare V8 context (no Node or Web globals — like JavaScriptCore) and
// provides a fake native layer mirroring App/Sources/YouTubeBridge/JSRuntime.swift.
import { readFileSync } from 'node:fs';
import { createHash, randomBytes } from 'node:crypto';
import vm from 'node:vm';

export const bundlePath = new URL('../../App/Resources/js/youtubei.bundle.js', import.meta.url);
const bundleCode = readFileSync(bundlePath, 'utf8');
const bundleScript = new vm.Script(bundleCode, { filename: 'youtubei.bundle.js' });

// `overrides` replaces single native functions (e.g. a clock that counts from device boot).
export function loadBundle({ natives = true, router = null, overrides = {} } = {}) {
  const context = vm.createContext({});
  const U8 = vm.runInContext('Uint8Array', context);
  const toCtxBytes = (buf) => {
    const out = new U8(buf.length);
    for (let i = 0; i < buf.length; i++) out[i] = buf[i];
    return out;
  };
  const logs = [];
  const requests = [];
  const pendingReplies = new Map();
  const cache = new Map();
  const timers = new Map();
  let replySeq = 0;

  if (natives) {
    context.__native = {
      log(level, message) {
        logs.push({ level, message });
        if (process.env.SMOKE_VERBOSE) console.log(`[js:${level}] ${message}`);
      },
      setTimer(id, ms) {
        const handle = setTimeout(() => {
          timers.delete(id);
          context.__tubeTimerFire(id);
        }, ms);
        timers.set(id, handle);
      },
      clearTimer(id) {
        clearTimeout(timers.get(id));
        timers.delete(id);
      },
      now() {
        return performance.now();
      },
      randomBytes(n) {
        return toCtxBytes(randomBytes(n));
      },
      utf8Encode(str) {
        return toCtxBytes(Buffer.from(str, 'utf8'));
      },
      utf8Decode(bytes) {
        return Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength).toString('utf8');
      },
      sha1Hex(str) {
        return createHash('sha1').update(str, 'utf8').digest('hex');
      },
      cacheGet(key) {
        return cache.has(key) ? toCtxBytes(cache.get(key)) : null;
      },
      cacheSet(key, bytes) {
        cache.set(key, Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength));
      },
      cacheRemove(key) {
        cache.delete(key);
      },
      fetch(id, url, method, headersJSON, body, redirect) {
        const headers = Object.fromEntries(JSON.parse(headersJSON));
        let bodyText = null;
        if (typeof body === 'string') bodyText = body;
        else if (body) bodyText = Buffer.from(body.buffer, body.byteOffset, body.byteLength).toString('utf8');
        const request = { url, method, headers, body: bodyText, redirect };
        requests.push(request);
        Promise.resolve()
          .then(() => (router ? router(request) : { status: 404, body: 'no router' }))
          .then((res) => {
            const r = res || { status: 404, body: 'not found' };
            const text = typeof r.body === 'string' ? r.body : JSON.stringify(r.body ?? '');
            const responseHeaders = Object.entries(r.headers || { 'content-type': 'application/json' });
            context.__tubeFetchDone(id, null, r.status || 200, r.statusText || 'OK', r.url || url,
              JSON.stringify(responseHeaders), toCtxBytes(Buffer.from(text, 'utf8')));
          })
          .catch((e) => context.__tubeFetchDone(id, String(e && e.message ? e.message : e), 0, '', url, '[]', null));
      },
      fetchCancel() {},
      reply(id, errorJSON, resultJSON) {
        const pending = pendingReplies.get(id);
        if (!pending) return;
        pendingReplies.delete(id);
        if (errorJSON) pending.reject(Object.assign(new Error('bridge error'), JSON.parse(errorJSON)));
        else pending.resolve(resultJSON == null ? null : JSON.parse(resultJSON));
      }
    };
    Object.assign(context.__native, overrides);
  }

  bundleScript.runInContext(context);

  function call(method, args = {}) {
    return new Promise((resolve, reject) => {
      const id = ++replySeq;
      pendingReplies.set(id, { resolve, reject });
      context.TubeBridge.call(id, method, JSON.stringify(args));
    });
  }

  function evaluate(code) {
    return vm.runInContext(code, context);
  }

  return { context, call, evaluate, logs, requests, cache };
}
