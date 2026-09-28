// fetch, Request, Response, Headers, Blob, File, FormData and a minimal ReadableStream.
// Network I/O is delegated to the host (`__native.fetch`, URLSession in the app).
import { nativeFn } from './native.js';
import { utf8Encode, utf8Decode, toUint8Array, exactBytes } from './encoding.js';
import { DOMException } from './events.js';
import { URLSearchParams } from './url.js';

// ---------------------------------------------------------------- Headers

function normalizeName(name) {
  const n = String(name).trim().toLowerCase();
  if (!/^[!#$%&'*+\-.^_`|~0-9a-z]+$/.test(n)) throw new TypeError(`Invalid header name: ${name}`);
  return n;
}

function normalizeValue(value) {
  return String(value).replace(/^[\t\n\r ]+|[\t\n\r ]+$/g, '');
}

export class Headers {
  constructor(init) {
    this._map = new Map(); // lower-case name -> string[]
    if (init == null) return;
    if (init instanceof Headers || (typeof init.forEach === 'function' && typeof init.get === 'function' && !Array.isArray(init))) {
      init.forEach((value, name) => this.append(name, value));
    } else if (Array.isArray(init) || typeof init[Symbol.iterator] === 'function') {
      for (const pair of init) {
        const arr = Array.from(pair);
        if (arr.length !== 2) throw new TypeError('Header pairs must contain exactly two items');
        this.append(arr[0], arr[1]);
      }
    } else if (typeof init === 'object') {
      for (const key of Object.keys(init)) this.append(key, init[key]);
    }
  }

  append(name, value) {
    const key = normalizeName(name);
    const list = this._map.get(key) || [];
    list.push(normalizeValue(value));
    this._map.set(key, list);
  }

  set(name, value) {
    this._map.set(normalizeName(name), [normalizeValue(value)]);
  }

  get(name) {
    const list = this._map.get(normalizeName(name));
    if (!list) return null;
    return list.join(', ');
  }

  getSetCookie() {
    return (this._map.get('set-cookie') || []).slice();
  }

  has(name) {
    return this._map.has(normalizeName(name));
  }

  delete(name) {
    this._map.delete(normalizeName(name));
  }

  forEach(callback, thisArg) {
    for (const [name, value] of this.entries()) callback.call(thisArg, value, name, this);
  }

  *entries() {
    const names = Array.from(this._map.keys()).sort();
    for (const name of names) {
      if (name === 'set-cookie') {
        for (const v of this._map.get(name)) yield [name, v];
      } else {
        yield [name, this._map.get(name).join(', ')];
      }
    }
  }

  *keys() {
    for (const [name] of this.entries()) yield name;
  }

  *values() {
    for (const [, value] of this.entries()) yield value;
  }

  [Symbol.iterator]() {
    return this.entries();
  }

  get [Symbol.toStringTag]() {
    return 'Headers';
  }
}

// ---------------------------------------------------------------- Blob / File / FormData

export class Blob {
  constructor(parts = [], options = {}) {
    const chunks = [];
    for (const part of parts) {
      if (part instanceof Blob) chunks.push(part._bytes);
      else if (typeof part === 'string') chunks.push(utf8Encode(part));
      else chunks.push(new Uint8Array(toUint8Array(part)));
    }
    const total = chunks.reduce((n, c) => n + c.length, 0);
    const bytes = new Uint8Array(total);
    let offset = 0;
    for (const c of chunks) {
      bytes.set(c, offset);
      offset += c.length;
    }
    this._bytes = bytes;
    this.type = options.type ? String(options.type).toLowerCase() : '';
  }
  get size() {
    return this._bytes.length;
  }
  async arrayBuffer() {
    return this._bytes.slice().buffer;
  }
  async bytes() {
    return this._bytes.slice();
  }
  async text() {
    return utf8Decode(this._bytes);
  }
  slice(start = 0, end = this._bytes.length, type = '') {
    const b = new Blob([], { type });
    b._bytes = this._bytes.slice(start, end);
    return b;
  }
  stream() {
    return new ReadableStream({
      start: (controller) => {
        controller.enqueue(this._bytes.slice());
        controller.close();
      }
    });
  }
}

export class File extends Blob {
  constructor(parts, name, options = {}) {
    super(parts, options);
    this.name = String(name);
    this.lastModified = options.lastModified || Date.now();
  }
}

export class FormData {
  constructor() {
    this._entries = [];
  }
  append(name, value, filename) {
    this._entries.push([String(name), this._wrap(value, filename)]);
  }
  set(name, value, filename) {
    this.delete(name);
    this.append(name, value, filename);
  }
  get(name) {
    const found = this._entries.find(([k]) => k === String(name));
    return found ? found[1] : null;
  }
  getAll(name) {
    return this._entries.filter(([k]) => k === String(name)).map(([, v]) => v);
  }
  has(name) {
    return this._entries.some(([k]) => k === String(name));
  }
  delete(name) {
    this._entries = this._entries.filter(([k]) => k !== String(name));
  }
  forEach(callback, thisArg) {
    for (const [k, v] of this._entries) callback.call(thisArg, v, k, this);
  }
  entries() {
    return this._entries.map(([k, v]) => [k, v])[Symbol.iterator]();
  }
  [Symbol.iterator]() {
    return this.entries();
  }
  _wrap(value, filename) {
    if (value instanceof Blob) {
      if (value instanceof File && filename === undefined) return value;
      return new File([value], filename !== undefined ? filename : 'blob', { type: value.type });
    }
    return String(value);
  }
  _serialize() {
    const boundary = '----TubeFormBoundary' + Math.random().toString(16).slice(2);
    const parts = [];
    for (const [name, value] of this._entries) {
      if (value instanceof File) {
        parts.push(`--${boundary}\r\nContent-Disposition: form-data; name="${name}"; filename="${value.name}"\r\nContent-Type: ${value.type || 'application/octet-stream'}\r\n\r\n`);
        parts.push(value);
        parts.push('\r\n');
      } else {
        parts.push(`--${boundary}\r\nContent-Disposition: form-data; name="${name}"\r\n\r\n${value}\r\n`);
      }
    }
    parts.push(`--${boundary}--\r\n`);
    return { bytes: new Blob(parts)._bytes, contentType: `multipart/form-data; boundary=${boundary}` };
  }
}

// ---------------------------------------------------------------- ReadableStream (minimal)

export class ReadableStream {
  constructor(source = {}) {
    this._queue = [];
    this._closed = false;
    this._error = null;
    this._waiters = [];
    this.locked = false;
    const controller = {
      enqueue: (chunk) => {
        this._queue.push(chunk);
        this._flush();
      },
      close: () => {
        this._closed = true;
        this._flush();
      },
      error: (e) => {
        this._error = e || new Error('Stream errored');
        this._flush();
      },
      desiredSize: 1
    };
    this._source = source;
    this._controller = controller;
    try {
      const started = source.start ? source.start(controller) : undefined;
      if (started && typeof started.then === 'function') started.catch((e) => controller.error(e));
    } catch (e) {
      controller.error(e);
    }
  }

  _flush() {
    while (this._waiters.length) {
      if (this._error) {
        this._waiters.shift().reject(this._error);
      } else if (this._queue.length) {
        this._waiters.shift().resolve({ done: false, value: this._queue.shift() });
      } else if (this._closed) {
        this._waiters.shift().resolve({ done: true, value: undefined });
      } else {
        break;
      }
    }
  }

  getReader() {
    if (this.locked) throw new TypeError('ReadableStream is locked');
    this.locked = true;
    return {
      read: () => new Promise((resolve, reject) => {
        this._waiters.push({ resolve, reject });
        if (!this._queue.length && !this._closed && !this._error && this._source.pull) {
          Promise.resolve(this._source.pull(this._controller)).catch((e) => this._controller.error(e));
        }
        this._flush();
      }),
      releaseLock: () => {
        this.locked = false;
      },
      cancel: async () => {
        this._closed = true;
        this._queue = [];
        if (this._source.cancel) await this._source.cancel();
        this._flush();
      },
      closed: Promise.resolve()
    };
  }

  cancel() {
    this._closed = true;
    this._queue = [];
    return Promise.resolve();
  }

  async *[Symbol.asyncIterator]() {
    const reader = this.getReader();
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) return;
        yield value;
      }
    } finally {
      reader.releaseLock();
    }
  }
}

// ---------------------------------------------------------------- Body

// Converts any BodyInit into { bytes: Uint8Array | null, text: string | null, contentType }
function extractBody(body) {
  if (body == null) return { bytes: null, text: null, contentType: null };
  if (typeof body === 'string') return { bytes: null, text: body, contentType: 'text/plain;charset=UTF-8' };
  if (body instanceof URLSearchParams) {
    return { bytes: null, text: body.toString(), contentType: 'application/x-www-form-urlencoded;charset=UTF-8' };
  }
  if (body instanceof FormData) {
    const { bytes, contentType } = body._serialize();
    return { bytes, text: null, contentType };
  }
  if (body instanceof Blob) return { bytes: body._bytes, text: null, contentType: body.type || null };
  if (body instanceof ReadableStream) {
    // Only fully-buffered streams (the ones our own Request/Response `.body` creates) are supported.
    if (!body._closed || body._error) throw new TypeError('Streaming request bodies are not supported');
    const chunks = body._queue.map((c) => (typeof c === 'string' ? utf8Encode(c) : toUint8Array(c)));
    return { bytes: new Blob(chunks)._bytes, text: null, contentType: null };
  }
  return { bytes: new Uint8Array(toUint8Array(body)), text: null, contentType: null };
}

const hooks = [];
export function addJSONResponseHook(fn) {
  hooks.push(fn);
}

class Body {
  _initBody(body) {
    const { bytes, text, contentType } = extractBody(body);
    this._bodyBytes = bytes;
    this._bodyText = text;
    this._bodyUsed = false;
    this._hasBody = bytes !== null || text !== null;
    return contentType;
  }

  get bodyUsed() {
    return this._bodyUsed;
  }

  get body() {
    if (!this._hasBody) return null;
    if (!this._stream) {
      const bytes = this._peekBytes();
      this._stream = new ReadableStream({
        start(controller) {
          if (bytes.length) controller.enqueue(bytes);
          controller.close();
        }
      });
    }
    return this._stream;
  }

  _peekBytes() {
    if (this._bodyBytes === null && this._bodyText !== null) this._bodyBytes = utf8Encode(this._bodyText);
    return this._bodyBytes || new Uint8Array(0);
  }

  _consume() {
    if (this._bodyUsed) return Promise.reject(new TypeError('Body has already been consumed.'));
    this._bodyUsed = true;
    return Promise.resolve();
  }

  async text() {
    await this._consume();
    if (this._bodyText !== null) return this._bodyText;
    if (this._bodyBytes === null) return '';
    this._bodyText = utf8Decode(this._bodyBytes);
    return this._bodyText;
  }

  async json() {
    const text = await this.text();
    const value = JSON.parse(text);
    for (const hook of hooks) {
      try {
        hook(this.url || '', value);
      } catch (e) {
        console.warn('response hook failed', e);
      }
    }
    return value;
  }

  async arrayBuffer() {
    await this._consume();
    const bytes = this._peekBytes();
    return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
  }

  async bytes() {
    await this._consume();
    return this._peekBytes().slice();
  }

  async blob() {
    await this._consume();
    return new Blob([this._peekBytes()], { type: (this.headers && this.headers.get('content-type')) || '' });
  }

  async formData() {
    throw new TypeError('formData() is not supported');
  }
}

// ---------------------------------------------------------------- Request / Response

const METHODS = ['DELETE', 'GET', 'HEAD', 'OPTIONS', 'POST', 'PUT', 'PATCH'];

export class Request extends Body {
  constructor(input, init = {}) {
    super();
    init = init || {};
    let source = null;
    if (input instanceof Request) {
      source = input;
      this.url = input.url;
    } else {
      this.url = String(input && typeof input === 'object' && 'href' in input ? input.href : input);
    }
    let method = init.method || (source ? source.method : 'GET');
    method = String(method);
    this.method = METHODS.includes(method.toUpperCase()) ? method.toUpperCase() : method;
    this.headers = new Headers(init.headers || (source ? source.headers : undefined));
    this.redirect = init.redirect || (source ? source.redirect : 'follow');
    this.credentials = init.credentials || (source ? source.credentials : 'same-origin');
    this.mode = init.mode || (source ? source.mode : 'cors');
    this.cache = init.cache || (source ? source.cache : 'default');
    this.referrer = init.referrer || (source ? source.referrer : 'about:client');
    this.signal = init.signal || (source ? source.signal : null);
    this.keepalive = !!init.keepalive;
    this.integrity = init.integrity || '';

    let body = init.body;
    if (body === undefined && source) {
      body = source._bodyText !== null ? source._bodyText : source._bodyBytes;
    }
    if (body != null && (this.method === 'GET' || this.method === 'HEAD')) {
      throw new TypeError('Request with GET/HEAD method cannot have body.');
    }
    const contentType = this._initBody(body);
    if (contentType && !this.headers.has('content-type')) this.headers.set('content-type', contentType);
  }

  clone() {
    if (this.bodyUsed) throw new TypeError('Request body is already used');
    return new Request(this);
  }
}

const REDIRECT_STATUSES = [301, 302, 303, 307, 308];

export class Response extends Body {
  constructor(body = null, init = {}) {
    super();
    init = init || {};
    const status = init.status === undefined ? 200 : Number(init.status);
    if (!init._internal && (status < 200 || status > 599)) {
      throw new RangeError(`Failed to construct 'Response': The status provided (${status}) is outside the range [200, 599].`);
    }
    this.status = status;
    this.statusText = init.statusText === undefined ? '' : String(init.statusText);
    this.headers = new Headers(init.headers);
    this.url = init._url || '';
    this.redirected = !!init._redirected;
    this.type = init._type || 'default';
    const contentType = this._initBody(body);
    if (contentType && !this.headers.has('content-type')) this.headers.set('content-type', contentType);
  }

  get ok() {
    return this.status >= 200 && this.status <= 299;
  }

  clone() {
    if (this.bodyUsed) throw new TypeError('Response body is already used');
    const copy = new Response(null, {
      status: this.status, statusText: this.statusText, headers: this.headers,
      _internal: true, _url: this.url, _redirected: this.redirected, _type: this.type
    });
    copy._bodyBytes = this._bodyBytes;
    copy._bodyText = this._bodyText;
    copy._hasBody = this._hasBody;
    return copy;
  }

  static error() {
    return new Response(null, { status: 0, statusText: '', _internal: true, _type: 'error' });
  }

  static redirect(url, status = 302) {
    if (!REDIRECT_STATUSES.includes(status)) throw new RangeError('Invalid status code');
    return new Response(null, { status, headers: { location: String(url) } });
  }

  static json(data, init = {}) {
    const headers = new Headers(init.headers);
    if (!headers.has('content-type')) headers.set('content-type', 'application/json');
    return new Response(JSON.stringify(data), { ...init, headers });
  }
}

// ---------------------------------------------------------------- fetch

let fetchSeq = 0;
const pendingFetches = new Map();

globalThis.__tubeFetchDone = function (id, error, status, statusText, finalUrl, headersJSON, body) {
  const pending = pendingFetches.get(id);
  if (!pending) return;
  pendingFetches.delete(id);
  if (pending.cleanup) pending.cleanup();
  if (error) {
    pending.reject(new TypeError(`Network request failed: ${error}`));
    return;
  }
  let headerPairs = [];
  try {
    headerPairs = headersJSON ? JSON.parse(headersJSON) : [];
  } catch {
    headerPairs = [];
  }
  const response = new Response(null, {
    status, statusText: statusText || '', headers: headerPairs, _internal: true,
    _url: finalUrl || pending.url, _redirected: !!finalUrl && finalUrl !== pending.url, _type: 'basic'
  });
  if (typeof body === 'string') {
    response._bodyText = body;
    response._hasBody = true;
  } else if (body != null) {
    response._bodyBytes = body instanceof Uint8Array ? body : new Uint8Array(toUint8Array(body));
    response._hasBody = true;
  }
  pending.resolve(response);
};

export function fetch(input, init) {
  return new Promise((resolve, reject) => {
    let request;
    try {
      request = new Request(input, init);
    } catch (e) {
      reject(e);
      return;
    }
    const signal = request.signal;
    if (signal && signal.aborted) {
      reject(signal.reason || new DOMException('The operation was aborted.', 'AbortError'));
      return;
    }
    const nativeFetch = nativeFn('fetch');
    if (!nativeFetch) {
      reject(new TypeError('Network request failed: no native fetch available'));
      return;
    }
    const id = ++fetchSeq;
    const entry = { resolve, reject, url: request.url, cleanup: null };
    pendingFetches.set(id, entry);
    if (signal) {
      const onAbort = () => {
        if (!pendingFetches.has(id)) return;
        pendingFetches.delete(id);
        const cancel = nativeFn('fetchCancel');
        if (cancel) cancel(id);
        reject(signal.reason || new DOMException('The operation was aborted.', 'AbortError'));
      };
      signal.addEventListener('abort', onAbort, { once: true });
      entry.cleanup = () => signal.removeEventListener('abort', onAbort);
    }
    const headerPairs = Array.from(request.headers.entries());
    const body = request._bodyText !== null ? request._bodyText : (request._bodyBytes ? exactBytes(request._bodyBytes) : null);
    try {
      nativeFetch(id, request.url, request.method, JSON.stringify(headerPairs), body === undefined ? null : body, request.redirect);
    } catch (e) {
      pendingFetches.delete(id);
      reject(new TypeError(`Network request failed: ${e && e.message ? e.message : e}`));
    }
  });
}
