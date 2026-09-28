// TextEncoder / TextDecoder (UTF-8), atob / btoa. Native fast paths when the host provides them.
import { nativeFn } from './native.js';

export function utf8Encode(str) {
  str = String(str);
  const nativeEncode = nativeFn('utf8Encode');
  if (nativeEncode && str.length > 64) {
    const out = nativeEncode(str);
    if (out instanceof Uint8Array) return out;
  }
  const bytes = [];
  for (let i = 0; i < str.length; i++) {
    let code = str.charCodeAt(i);
    if (code >= 0xd800 && code <= 0xdbff && i + 1 < str.length) {
      const next = str.charCodeAt(i + 1);
      if (next >= 0xdc00 && next <= 0xdfff) {
        code = 0x10000 + ((code - 0xd800) << 10) + (next - 0xdc00);
        i++;
      } else {
        code = 0xfffd;
      }
    } else if (code >= 0xd800 && code <= 0xdfff) {
      code = 0xfffd;
    }
    if (code < 0x80) {
      bytes.push(code);
    } else if (code < 0x800) {
      bytes.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
    } else if (code < 0x10000) {
      bytes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
    } else {
      bytes.push(0xf0 | (code >> 18), 0x80 | ((code >> 12) & 0x3f), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
    }
  }
  return new Uint8Array(bytes);
}

export function toUint8Array(input) {
  if (input == null) return new Uint8Array(0);
  if (input instanceof Uint8Array) return input;
  if (input instanceof ArrayBuffer) return new Uint8Array(input);
  if (ArrayBuffer.isView(input)) return new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
  // Cross-realm buffers (e.g. created by a test harness) still quack like ArrayBuffers.
  if (typeof input.byteLength === 'number' && typeof input.slice === 'function') return new Uint8Array(input);
  throw new TypeError('Expected an ArrayBuffer or ArrayBufferView');
}

// Typed arrays handed to the host always start at offset 0 of their own buffer, so the host
// never has to care about views into larger buffers.
export function exactBytes(bytes) {
  const u8 = toUint8Array(bytes);
  return u8.byteOffset === 0 && u8.byteLength === u8.buffer.byteLength ? u8 : u8.slice();
}

export function utf8Decode(input) {
  const bytes = toUint8Array(input);
  const nativeDecode = nativeFn('utf8Decode');
  if (nativeDecode && bytes.length > 64) {
    const out = nativeDecode(exactBytes(bytes));
    if (typeof out === 'string') return out;
  }
  let out = '';
  const chunk = [];
  const flush = () => {
    out += String.fromCharCode.apply(null, chunk);
    chunk.length = 0;
  };
  let i = 0;
  // Skip BOM
  if (bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) i = 3;
  while (i < bytes.length) {
    const b0 = bytes[i];
    let code = 0xfffd;
    let size = 1;
    if (b0 < 0x80) {
      code = b0;
    } else if (b0 >= 0xc2 && b0 <= 0xdf && i + 1 < bytes.length && (bytes[i + 1] & 0xc0) === 0x80) {
      code = ((b0 & 0x1f) << 6) | (bytes[i + 1] & 0x3f);
      size = 2;
    } else if (b0 >= 0xe0 && b0 <= 0xef && i + 2 < bytes.length &&
      (bytes[i + 1] & 0xc0) === 0x80 && (bytes[i + 2] & 0xc0) === 0x80) {
      const c = ((b0 & 0x0f) << 12) | ((bytes[i + 1] & 0x3f) << 6) | (bytes[i + 2] & 0x3f);
      if (c >= 0x800 && (c < 0xd800 || c > 0xdfff)) {
        code = c;
        size = 3;
      }
    } else if (b0 >= 0xf0 && b0 <= 0xf4 && i + 3 < bytes.length &&
      (bytes[i + 1] & 0xc0) === 0x80 && (bytes[i + 2] & 0xc0) === 0x80 && (bytes[i + 3] & 0xc0) === 0x80) {
      const c = ((b0 & 0x07) << 18) | ((bytes[i + 1] & 0x3f) << 12) | ((bytes[i + 2] & 0x3f) << 6) | (bytes[i + 3] & 0x3f);
      if (c >= 0x10000 && c <= 0x10ffff) {
        code = c;
        size = 4;
      }
    }
    if (code > 0xffff) {
      code -= 0x10000;
      chunk.push(0xd800 + (code >> 10), 0xdc00 + (code & 0x3ff));
    } else {
      chunk.push(code);
    }
    i += size;
    if (chunk.length >= 8192) flush();
  }
  flush();
  return out;
}

function latin1Decode(input) {
  const bytes = toUint8Array(input);
  let out = '';
  for (let i = 0; i < bytes.length; i += 8192) {
    out += String.fromCharCode.apply(null, bytes.subarray(i, i + 8192));
  }
  return out;
}

export class TextEncoder {
  get encoding() {
    return 'utf-8';
  }
  encode(input = '') {
    return utf8Encode(input);
  }
  encodeInto(input, dest) {
    const bytes = utf8Encode(input);
    const written = Math.min(bytes.length, dest.length);
    dest.set(bytes.subarray(0, written));
    return { read: input.length, written };
  }
}

export class TextDecoder {
  constructor(label = 'utf-8', options = {}) {
    const normalized = String(label).trim().toLowerCase();
    this._encoding = normalized === 'utf8' ? 'utf-8' : normalized;
    this.fatal = !!options.fatal;
    this.ignoreBOM = !!options.ignoreBOM;
  }
  get encoding() {
    return this._encoding;
  }
  decode(input) {
    if (input === undefined) return '';
    if (this._encoding === 'utf-8') return utf8Decode(input);
    if (this._encoding === 'utf-16le' || this._encoding === 'utf-16') {
      const bytes = toUint8Array(input);
      let out = '';
      for (let i = 0; i + 1 < bytes.length; i += 2) out += String.fromCharCode(bytes[i] | (bytes[i + 1] << 8));
      return out;
    }
    return latin1Decode(input);
  }
}

const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
const B64_LOOKUP = (() => {
  const table = new Int16Array(256).fill(-1);
  for (let i = 0; i < B64.length; i++) table[B64.charCodeAt(i)] = i;
  table['-'.charCodeAt(0)] = 62;
  table['_'.charCodeAt(0)] = 63;
  return table;
})();

export function btoa(input) {
  const str = String(input);
  let out = '';
  for (let i = 0; i < str.length; i += 3) {
    const a = str.charCodeAt(i);
    const b = i + 1 < str.length ? str.charCodeAt(i + 1) : NaN;
    const c = i + 2 < str.length ? str.charCodeAt(i + 2) : NaN;
    if (a > 255 || b > 255 || c > 255) {
      throw new Error("InvalidCharacterError: btoa() argument contains characters outside of the Latin1 range");
    }
    const triple = (a << 16) | ((b || 0) << 8) | (c || 0);
    out += B64[(triple >> 18) & 63] + B64[(triple >> 12) & 63] +
      (Number.isNaN(b) ? '=' : B64[(triple >> 6) & 63]) +
      (Number.isNaN(c) ? '=' : B64[triple & 63]);
  }
  return out;
}

export function atob(input) {
  const str = String(input).replace(/[\t\n\f\r ]+/g, '').replace(/=+$/, '');
  if (str.length % 4 === 1) throw new Error('InvalidCharacterError: The string to be decoded is not correctly encoded.');
  let out = '';
  let buffer = 0;
  let bits = 0;
  for (let i = 0; i < str.length; i++) {
    const value = B64_LOOKUP[str.charCodeAt(i) & 0xff];
    if (value < 0 || str.charCodeAt(i) > 255) {
      throw new Error('InvalidCharacterError: The string to be decoded is not correctly encoded.');
    }
    buffer = (buffer << 6) | value;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out += String.fromCharCode((buffer >> bits) & 0xff);
    }
  }
  return out;
}

export function bytesToBase64(bytes) {
  return btoa(latin1Decode(bytes));
}

export function base64ToBytes(b64) {
  const bin = atob(String(b64).replace(/-/g, '+').replace(/_/g, '/'));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
