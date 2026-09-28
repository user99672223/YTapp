// URL and URLSearchParams for JavaScriptCore (which ships neither outside WebKit).
// A pragmatic subset of the WHATWG URL Standard: special schemes (http, https, ws, wss, ftp, file)
// with authority parsing, relative resolution, dot-segment removal and the standard
// percent-encode sets; opaque paths for everything else (data:, about:, mailto: ...).
import { utf8Encode, utf8Decode } from './encoding.js';

const SPECIAL = { 'http:': '80', 'https:': '443', 'ws:': '80', 'wss:': '443', 'ftp:': '21', 'file:': '' };

const HEX = '0123456789ABCDEF';

function percentEncodeBytes(str, shouldEncode) {
  let out = '';
  for (let i = 0; i < str.length; i++) {
    const code = str.charCodeAt(i);
    if (code < 0x80) {
      const ch = str[i];
      if (shouldEncode(code, ch)) {
        out += '%' + HEX[code >> 4] + HEX[code & 15];
      } else {
        out += ch;
      }
      continue;
    }
    // Non-ASCII: encode the UTF-8 bytes of the full code point.
    let cp = str[i];
    if (code >= 0xd800 && code <= 0xdbff && i + 1 < str.length) {
      cp += str[i + 1];
      i++;
    }
    const bytes = utf8Encode(cp);
    for (const b of bytes) out += '%' + HEX[b >> 4] + HEX[b & 15];
  }
  return out;
}

const C0 = (c) => c <= 0x1f || c === 0x7f;
const FRAGMENT_SET = (c, ch) => C0(c) || ch === ' ' || ch === '"' || ch === '<' || ch === '>' || ch === '`';
const QUERY_SET = (c, ch) => C0(c) || ch === ' ' || ch === '"' || ch === '#' || ch === '<' || ch === '>';
const SPECIAL_QUERY_SET = (c, ch) => QUERY_SET(c, ch) || ch === "'";
const PATH_SET = (c, ch) => QUERY_SET(c, ch) || ch === '?' || ch === '`' || ch === '{' || ch === '}' || ch === '^';
const USERINFO_SET = (c, ch) => PATH_SET(c, ch) || '/:;=@[\\]|'.includes(ch);

// application/x-www-form-urlencoded byte serializer
function formEncode(str) {
  const bytes = utf8Encode(String(str));
  let out = '';
  for (const b of bytes) {
    if ((b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5a) || (b >= 0x61 && b <= 0x7a) ||
      b === 0x2a || b === 0x2d || b === 0x2e || b === 0x5f) {
      out += String.fromCharCode(b);
    } else if (b === 0x20) {
      out += '+';
    } else {
      out += '%' + HEX[b >> 4] + HEX[b & 15];
    }
  }
  return out;
}

function isHex(c) {
  return (c >= 48 && c <= 57) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102);
}

export function percentDecode(str) {
  if (str.indexOf('%') === -1) return str;
  const bytes = utf8Encode(str);
  const out = [];
  for (let i = 0; i < bytes.length; i++) {
    const b = bytes[i];
    if (b === 0x25 && i + 2 < bytes.length && isHex(bytes[i + 1]) && isHex(bytes[i + 2])) {
      out.push(parseInt(String.fromCharCode(bytes[i + 1], bytes[i + 2]), 16));
      i += 2;
    } else {
      out.push(b);
    }
  }
  return utf8Decode(new Uint8Array(out));
}

function formDecode(str) {
  return percentDecode(str.replace(/\+/g, ' '));
}

export class URLSearchParams {
  constructor(init) {
    this._list = [];
    this._url = null;
    if (init == null || init === '') return;
    if (init instanceof URLSearchParams) {
      this._list = init._list.map(([k, v]) => [k, v]);
    } else if (typeof init === 'object' && typeof init[Symbol.iterator] === 'function') {
      for (const pair of init) {
        const arr = Array.from(pair);
        if (arr.length !== 2) throw new TypeError('Each query pair must be an iterable [name, value] tuple');
        this._list.push([String(arr[0]), String(arr[1])]);
      }
    } else if (typeof init === 'object') {
      for (const key of Object.keys(init)) this._list.push([key, String(init[key])]);
    } else {
      this._parse(String(init));
    }
  }

  _parse(str) {
    this._list = [];
    if (str.startsWith('?')) str = str.slice(1);
    for (const part of str.split('&')) {
      if (!part) continue;
      const eq = part.indexOf('=');
      const name = eq === -1 ? part : part.slice(0, eq);
      const value = eq === -1 ? '' : part.slice(eq + 1);
      this._list.push([formDecode(name), formDecode(value)]);
    }
  }

  _update() {
    if (this._url) {
      const serialized = this.toString();
      this._url._query = serialized === '' ? null : serialized;
    }
  }

  get size() {
    return this._list.length;
  }

  append(name, value) {
    this._list.push([String(name), String(value)]);
    this._update();
  }

  delete(name, value) {
    name = String(name);
    this._list = this._list.filter(([k, v]) => !(k === name && (value === undefined || v === String(value))));
    this._update();
  }

  get(name) {
    name = String(name);
    const found = this._list.find(([k]) => k === name);
    return found ? found[1] : null;
  }

  getAll(name) {
    name = String(name);
    return this._list.filter(([k]) => k === name).map(([, v]) => v);
  }

  has(name, value) {
    name = String(name);
    return this._list.some(([k, v]) => k === name && (value === undefined || v === String(value)));
  }

  set(name, value) {
    name = String(name);
    value = String(value);
    const index = this._list.findIndex(([k]) => k === name);
    if (index === -1) {
      this._list.push([name, value]);
    } else {
      this._list[index][1] = value;
      this._list = this._list.filter(([k], i) => k !== name || i === index);
    }
    this._update();
  }

  sort() {
    this._list = this._list
      .map((pair, index) => ({ pair, index }))
      .sort((a, b) => (a.pair[0] < b.pair[0] ? -1 : a.pair[0] > b.pair[0] ? 1 : a.index - b.index))
      .map(({ pair }) => pair);
    this._update();
  }

  forEach(callback, thisArg) {
    for (const [k, v] of this._list.slice()) callback.call(thisArg, v, k, this);
  }

  keys() {
    return this._list.map(([k]) => k)[Symbol.iterator]();
  }

  values() {
    return this._list.map(([, v]) => v)[Symbol.iterator]();
  }

  entries() {
    return this._list.map(([k, v]) => [k, v])[Symbol.iterator]();
  }

  [Symbol.iterator]() {
    return this.entries();
  }

  toString() {
    return this._list.map(([k, v]) => `${formEncode(k)}=${formEncode(v)}`).join('&');
  }

  get [Symbol.toStringTag]() {
    return 'URLSearchParams';
  }
}

function removeDotSegments(segments) {
  const out = [];
  for (let i = 0; i < segments.length; i++) {
    const seg = segments[i];
    const lower = seg.toLowerCase();
    const isLast = i === segments.length - 1;
    if (seg === '..' || lower === '.%2e' || lower === '%2e.' || lower === '%2e%2e') {
      if (out.length > 0) out.pop();
      if (isLast) out.push('');
    } else if (seg === '.' || lower === '%2e') {
      if (isLast) out.push('');
    } else {
      out.push(seg);
    }
  }
  return out;
}

function parseHost(host, special) {
  if (host.startsWith('[')) {
    if (!host.endsWith(']')) throw new TypeError('Invalid URL: bad IPv6 host');
    return host.toLowerCase();
  }
  const decoded = percentDecode(host);
  if (special) {
    if (decoded === '' ) throw new TypeError('Invalid URL: empty host');
    if (/[\u0000\t\n\r #/:<>?@[\\\]^|%]/.test(decoded)) throw new TypeError('Invalid URL: forbidden host code point');
    return decoded.toLowerCase();
  }
  return percentEncodeBytes(host, (c) => C0(c) || c === 0x20);
}

function splitSuffix(rest) {
  let fragment = null;
  const hashIndex = rest.indexOf('#');
  if (hashIndex !== -1) {
    fragment = rest.slice(hashIndex + 1);
    rest = rest.slice(0, hashIndex);
  }
  let query = null;
  const qIndex = rest.indexOf('?');
  if (qIndex !== -1) {
    query = rest.slice(qIndex + 1);
    rest = rest.slice(0, qIndex);
  }
  return { path: rest, query, fragment };
}

function parseAbsolute(input) {
  const m = /^([a-zA-Z][a-zA-Z0-9+.-]*):(.*)$/s.exec(input);
  if (!m) return null;
  const protocol = m[1].toLowerCase() + ':';
  let rest = m[2];
  const special = Object.prototype.hasOwnProperty.call(SPECIAL, protocol);
  const record = {
    protocol, special, username: '', password: '', hostname: '', port: '', path: '', opaque: false,
    _query: null, fragment: null
  };
  if (special) rest = rest.replace(/\\/g, '/');
  if (special || rest.startsWith('//')) {
    if (special) rest = rest.replace(/^\/*/, '');
    else rest = rest.slice(2);
    let authorityEnd = rest.search(/[/?#]/);
    if (authorityEnd === -1) authorityEnd = rest.length;
    let authority = rest.slice(0, authorityEnd);
    rest = rest.slice(authorityEnd);
    const at = authority.lastIndexOf('@');
    if (at !== -1) {
      const userinfo = authority.slice(0, at);
      authority = authority.slice(at + 1);
      const colon = userinfo.indexOf(':');
      record.username = percentEncodeBytes(colon === -1 ? userinfo : userinfo.slice(0, colon), USERINFO_SET);
      record.password = colon === -1 ? '' : percentEncodeBytes(userinfo.slice(colon + 1), USERINFO_SET);
    }
    let hostPart = authority;
    let portPart = '';
    const portMatch = /:(\d*)$/.exec(authority);
    if (portMatch && !authority.endsWith(']')) {
      hostPart = authority.slice(0, portMatch.index);
      portPart = portMatch[1];
    } else if (/:[^\]]*$/.test(authority) && !authority.startsWith('[')) {
      throw new TypeError('Invalid URL: bad port');
    }
    if (protocol !== 'file:' || hostPart !== '') record.hostname = parseHost(hostPart, special);
    if (portPart !== '') {
      const port = parseInt(portPart, 10);
      if (port > 65535) throw new TypeError('Invalid URL: port out of range');
      record.port = String(port) === SPECIAL[protocol] ? '' : String(port);
    }
    const { path, query, fragment } = splitSuffix(rest);
    record.path = normalizePath(path, special);
    record._query = query === null ? null : percentEncodeBytes(query, special ? SPECIAL_QUERY_SET : QUERY_SET);
    record.fragment = fragment === null ? null : percentEncodeBytes(fragment, FRAGMENT_SET);
    return record;
  }
  // Non-special scheme
  const { path, query, fragment } = splitSuffix(rest);
  if (path.startsWith('/')) {
    record.path = normalizePath(path, false);
  } else {
    record.opaque = true;
    record.path = percentEncodeBytes(path, C0);
  }
  record._query = query === null ? null : percentEncodeBytes(query, QUERY_SET);
  record.fragment = fragment === null ? null : percentEncodeBytes(fragment, FRAGMENT_SET);
  return record;
}

function normalizePath(path, special) {
  if (special && path === '') return '/';
  if (path === '') return '';
  const segments = path.split('/').slice(1); // path always begins with '/'
  const cleaned = removeDotSegments(segments).map((s) => percentEncodeBytes(s, PATH_SET));
  return '/' + cleaned.join('/');
}

function resolveRelative(input, base) {
  if (base.opaque) {
    if (input.startsWith('#')) {
      return { ...base, fragment: percentEncodeBytes(input.slice(1), FRAGMENT_SET) };
    }
    throw new TypeError('Invalid URL');
  }
  if (base.special) input = input.replace(/\\/g, '/');
  if (input.startsWith('//')) return parseAbsolute(base.protocol + input);
  const record = { ...base, fragment: null };
  const { path, query, fragment } = splitSuffix(input);
  const encQuery = (q) => (q === null ? null : percentEncodeBytes(q, base.special ? SPECIAL_QUERY_SET : QUERY_SET));
  record.fragment = fragment === null ? null : percentEncodeBytes(fragment, FRAGMENT_SET);
  if (path === '') {
    record._query = query === null ? base._query : encQuery(query);
    return record;
  }
  record._query = encQuery(query);
  if (path.startsWith('/')) {
    record.path = normalizePath(path, base.special);
    return record;
  }
  const baseDir = base.path.slice(0, base.path.lastIndexOf('/') + 1) || '/';
  record.path = normalizePath(baseDir + path, base.special);
  return record;
}

export class URL {
  constructor(url, base) {
    const input = String(url instanceof URL ? url.href : url).replace(/^[\u0000- ]+|[\u0000- ]+$/g, '').replace(/[\t\n\r]/g, '');
    let record = parseAbsolute(input);
    if (!record) {
      if (base === undefined) throw new TypeError(`Invalid URL: ${input}`);
      const baseRecord = base instanceof URL ? base._record() : new URL(String(base))._record();
      record = resolveRelative(input, baseRecord);
    }
    Object.assign(this, record);
    this._searchParams = new URLSearchParams(this._query || '');
    this._searchParams._url = this;
  }

  static canParse(url, base) {
    try {
      // eslint-disable-next-line no-new
      new URL(url, base);
      return true;
    } catch {
      return false;
    }
  }

  static parse(url, base) {
    try {
      return new URL(url, base);
    } catch {
      return null;
    }
  }

  _record() {
    return {
      protocol: this.protocol, special: this.special, username: this.username, password: this.password,
      hostname: this.hostname, port: this.port, path: this.path, opaque: this.opaque,
      _query: this._query, fragment: this.fragment
    };
  }

  get host() {
    return this.port ? `${this.hostname}:${this.port}` : this.hostname;
  }

  set host(value) {
    const parsed = parseAbsolute(`${this.protocol}//${value}`);
    if (parsed) {
      this.hostname = parsed.hostname;
      this.port = parsed.port;
    }
  }

  get origin() {
    if (this.special && this.protocol !== 'file:') return `${this.protocol}//${this.host}`;
    return 'null';
  }

  get pathname() {
    return this.path;
  }

  set pathname(value) {
    if (this.opaque) return;
    const v = String(value);
    this.path = normalizePath(v.startsWith('/') ? v : '/' + v, this.special);
  }

  get search() {
    return this._query ? `?${this._query}` : '';
  }

  set search(value) {
    let v = String(value);
    if (v.startsWith('?')) v = v.slice(1);
    this._query = v === '' ? null : percentEncodeBytes(v, this.special ? SPECIAL_QUERY_SET : QUERY_SET);
    this._searchParams._list = [];
    this._searchParams._parse(this._query || '');
  }

  get searchParams() {
    return this._searchParams;
  }

  get hash() {
    return this.fragment ? `#${this.fragment}` : '';
  }

  set hash(value) {
    let v = String(value);
    if (v.startsWith('#')) v = v.slice(1);
    this.fragment = v === '' ? null : percentEncodeBytes(v, FRAGMENT_SET);
  }

  get href() {
    let out = this.protocol;
    if (this.hostname !== '' || this.special) {
      out += '//';
      if (this.username || this.password) {
        out += this.username;
        if (this.password) out += ':' + this.password;
        out += '@';
      }
      out += this.host;
    }
    out += this.path;
    if (this._query !== null) out += '?' + this._query;
    if (this.fragment !== null) out += '#' + this.fragment;
    return out;
  }

  set href(value) {
    const next = new URL(value);
    Object.assign(this, next._record());
    this._searchParams = new URLSearchParams(this._query || '');
    this._searchParams._url = this;
  }

  toString() {
    return this.href;
  }

  toJSON() {
    return this.href;
  }

  get [Symbol.toStringTag]() {
    return 'URL';
  }
}
