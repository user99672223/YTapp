// Installs the Web platform pieces JavaScriptCore lacks. Imported first by the bundle entry so
// everything exists before YouTube.js modules evaluate.
import {
  makeConsole, reportError, setTimeout, setInterval, clearTimeout, clearInterval, setImmediate,
  clearImmediate, queueMicrotask, performance, crypto, structuredClone
} from './base.js';
import { TextEncoder, TextDecoder, atob, btoa } from './encoding.js';
import { URL, URLSearchParams } from './url.js';
import { Event, CustomEvent, EventTarget, DOMException, AbortController, AbortSignal } from './events.js';
import { fetch, Headers, Request, Response, Blob, File, FormData, ReadableStream } from './fetch.js';

const g = globalThis;

function define(name, value, force = false) {
  if (!force && typeof g[name] !== 'undefined') return;
  Object.defineProperty(g, name, { value, writable: true, configurable: true, enumerable: false });
}

// Always ours: the host console only reaches the Web Inspector.
define('console', makeConsole(), true);
define('reportError', reportError);
define('self', g);

define('setTimeout', setTimeout);
define('setInterval', setInterval);
define('clearTimeout', clearTimeout);
define('clearInterval', clearInterval);
define('setImmediate', setImmediate);
define('clearImmediate', clearImmediate);
define('queueMicrotask', queueMicrotask);
define('performance', performance);
define('structuredClone', structuredClone);

define('TextEncoder', TextEncoder);
define('TextDecoder', TextDecoder);
define('atob', atob);
define('btoa', btoa);

define('URL', URL);
define('URLSearchParams', URLSearchParams);

define('Event', Event);
define('CustomEvent', CustomEvent);
define('EventTarget', EventTarget);
define('DOMException', DOMException);
define('AbortController', AbortController);
define('AbortSignal', AbortSignal);

if (typeof g.crypto === 'undefined' || typeof g.crypto.getRandomValues !== 'function') {
  define('crypto', crypto, true);
} else if (typeof g.crypto.randomUUID !== 'function') {
  g.crypto.randomUUID = crypto.randomUUID;
}

// Networking always goes through the native bridge, so these are always ours.
define('fetch', fetch, true);
define('Headers', Headers, true);
define('Request', Request, true);
define('Response', Response, true);
define('Blob', Blob);
define('File', File);
define('FormData', FormData);
define('ReadableStream', ReadableStream);

export const installed = true;
