// A minimal DOM for BotGuard (PO tokens). Installed lazily, only when a stream client that needs
// PO tokens is selected. BotGuard inspects its environment; this shim provides the common
// surface (window/document/navigator/screen/storage/observers). It is not a real browser, so the
// integrity token YouTube issues may still be rejected — failures surface as on-screen errors.

class ShimStorage {
  constructor() {
    this._data = new Map();
  }
  get length() {
    return this._data.size;
  }
  key(i) {
    return Array.from(this._data.keys())[i] ?? null;
  }
  getItem(k) {
    return this._data.has(String(k)) ? this._data.get(String(k)) : null;
  }
  setItem(k, v) {
    this._data.set(String(k), String(v));
  }
  removeItem(k) {
    this._data.delete(String(k));
  }
  clear() {
    this._data.clear();
  }
}

export function installDomShim(userAgent) {
  const g = globalThis;
  if (g.__tubeDomShimInstalled) return;
  g.__tubeDomShimInstalled = true;
  const ET = g.EventTarget;

  class Node extends ET {
    constructor(name) {
      super();
      this.nodeName = name;
      this.childNodes = [];
      this.parentNode = null;
      this.ownerDocument = null;
    }
    appendChild(child) {
      if (child && child.parentNode) child.parentNode.removeChild(child);
      this.childNodes.push(child);
      if (child) child.parentNode = this;
      if (child && child.tagName === 'SCRIPT' && child.textContent && !child.src) {
        try {
          // eslint-disable-next-line no-new-func
          new Function(child.textContent)();
        } catch (e) {
          console.warn('dom shim: inline script failed', e && e.message);
        }
      }
      return child;
    }
    append(...nodes) {
      nodes.forEach((n) => this.appendChild(typeof n === 'string' ? g.document.createTextNode(n) : n));
    }
    prepend(...nodes) {
      nodes.reverse().forEach((n) => this.insertBefore(n, this.childNodes[0] || null));
    }
    insertBefore(child, ref) {
      const i = ref ? this.childNodes.indexOf(ref) : -1;
      if (i < 0) return this.appendChild(child);
      this.childNodes.splice(i, 0, child);
      child.parentNode = this;
      return child;
    }
    removeChild(child) {
      const i = this.childNodes.indexOf(child);
      if (i >= 0) this.childNodes.splice(i, 1);
      if (child) child.parentNode = null;
      return child;
    }
    remove() {
      if (this.parentNode) this.parentNode.removeChild(this);
    }
    contains(node) {
      if (node === this) return true;
      return this.childNodes.some((c) => c && typeof c.contains === 'function' && c.contains(node));
    }
    get firstChild() {
      return this.childNodes[0] || null;
    }
    get lastChild() {
      return this.childNodes[this.childNodes.length - 1] || null;
    }
    get children() {
      return this.childNodes.filter((c) => c instanceof Element);
    }
    cloneNode() {
      return new this.constructor(this.nodeName);
    }
    hasChildNodes() {
      return this.childNodes.length > 0;
    }
  }

  class Element extends Node {
    constructor(tag) {
      super(String(tag).toUpperCase());
      this.tagName = String(tag).toUpperCase();
      this.localName = String(tag).toLowerCase();
      this.style = new Proxy({ cssText: '' }, {
        get: (t, p) => (p in t ? t[p] : typeof p === 'string' && (p === 'getPropertyValue') ? () => '' : ''),
        set: (t, p, v) => {
          t[p] = v;
          return true;
        }
      });
      this._attrs = new Map();
      this.dataset = {};
      this.classList = {
        _set: new Set(),
        add: (...c) => c.forEach((x) => this.classList._set.add(x)),
        remove: (...c) => c.forEach((x) => this.classList._set.delete(x)),
        contains: (c) => this.classList._set.has(c),
        toggle: (c) => (this.classList._set.has(c) ? (this.classList._set.delete(c), false) : (this.classList._set.add(c), true))
      };
      this.textContent = '';
      this.innerHTML = '';
      this.id = '';
      this.className = '';
    }
    setAttribute(k, v) {
      this._attrs.set(String(k), String(v));
      if (k === 'id') this.id = String(v);
    }
    getAttribute(k) {
      return this._attrs.has(String(k)) ? this._attrs.get(String(k)) : null;
    }
    hasAttribute(k) {
      return this._attrs.has(String(k));
    }
    removeAttribute(k) {
      this._attrs.delete(String(k));
    }
    get attributes() {
      return Array.from(this._attrs, ([name, value]) => ({ name, value }));
    }
    getBoundingClientRect() {
      return { x: 0, y: 0, top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0, toJSON() { return this; } };
    }
    getClientRects() {
      return [];
    }
    querySelector() {
      return null;
    }
    querySelectorAll() {
      return [];
    }
    getElementsByTagName() {
      return [];
    }
    getElementsByClassName() {
      return [];
    }
    closest() {
      return null;
    }
    matches() {
      return false;
    }
    focus() {}
    blur() {}
    click() {
      this.dispatchEvent(new g.Event('click'));
    }
    get offsetWidth() {
      return 0;
    }
    get offsetHeight() {
      return 0;
    }
    get clientWidth() {
      return 0;
    }
    get clientHeight() {
      return 0;
    }
    attachShadow() {
      return new Element('shadow-root');
    }
  }

  class HTMLElement extends Element {}
  class HTMLDivElement extends HTMLElement {}
  class HTMLSpanElement extends HTMLElement {}
  class HTMLScriptElement extends HTMLElement {
    constructor(tag) {
      super(tag);
      this.src = '';
      this.type = '';
      this.async = false;
    }
  }
  class HTMLCanvasElement extends HTMLElement {
    constructor(tag) {
      super(tag);
      this.width = 300;
      this.height = 150;
    }
    getContext() {
      return null;
    }
    toDataURL() {
      return 'data:,';
    }
  }
  class HTMLIFrameElement extends HTMLElement {
    get contentWindow() {
      return g;
    }
    get contentDocument() {
      return g.document;
    }
  }
  class HTMLImageElement extends HTMLElement {
    constructor(w, h) {
      super('img');
      this.width = w || 0;
      this.height = h || 0;
      this.complete = true;
      this.naturalWidth = 0;
      this.naturalHeight = 0;
    }
  }
  class HTMLVideoElement extends HTMLElement {
    canPlayType() {
      return '';
    }
  }
  class Text extends Node {
    constructor(data) {
      super('#text');
      this.data = String(data);
      this.textContent = this.data;
    }
  }

  const TAGS = {
    div: HTMLDivElement, span: HTMLSpanElement, script: HTMLScriptElement, canvas: HTMLCanvasElement,
    iframe: HTMLIFrameElement, img: HTMLImageElement, video: HTMLVideoElement
  };

  class Document extends Node {
    constructor() {
      super('#document');
      this.documentElement = new HTMLElement('html');
      this.head = new HTMLElement('head');
      this.body = new HTMLElement('body');
      this.documentElement.appendChild(this.head);
      this.documentElement.appendChild(this.body);
      this.childNodes.push(this.documentElement);
      this.cookie = '';
      this.readyState = 'complete';
      this.visibilityState = 'visible';
      this.hidden = false;
      this.referrer = 'https://www.youtube.com/';
      this.title = 'YouTube';
      this.characterSet = 'UTF-8';
      this.compatMode = 'CSS1Compat';
      this.contentType = 'text/html';
      this.fonts = { ready: Promise.resolve(), check: () => true, forEach() {} };
    }
    get location() {
      return g.location;
    }
    get URL() {
      return g.location.href;
    }
    get domain() {
      return g.location.hostname;
    }
    createElement(tag) {
      const Cls = TAGS[String(tag).toLowerCase()] || HTMLElement;
      const el = new Cls(tag);
      el.ownerDocument = this;
      return el;
    }
    createElementNS(ns, tag) {
      return this.createElement(tag);
    }
    createTextNode(data) {
      return new Text(data);
    }
    createDocumentFragment() {
      return new HTMLElement('#fragment');
    }
    createEvent() {
      return new g.Event('');
    }
    getElementById() {
      return null;
    }
    getElementsByTagName(tag) {
      const t = String(tag).toLowerCase();
      if (t === 'head') return [this.head];
      if (t === 'body') return [this.body];
      if (t === 'html') return [this.documentElement];
      return [];
    }
    getElementsByClassName() {
      return [];
    }
    querySelector(sel) {
      if (sel === 'head') return this.head;
      if (sel === 'body') return this.body;
      return null;
    }
    querySelectorAll() {
      return [];
    }
    hasFocus() {
      return true;
    }
    get activeElement() {
      return this.body;
    }
    get scrollingElement() {
      return this.documentElement;
    }
  }

  class Observer {
    constructor(callback) {
      this.callback = callback;
    }
    observe() {}
    unobserve() {}
    disconnect() {}
    takeRecords() {
      return [];
    }
  }

  const ua = userAgent || 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';
  const location = new g.URL('https://www.youtube.com/');
  location.assign = () => {};
  location.replace = () => {};
  location.reload = () => {};
  location.ancestorOrigins = [];

  const navigatorShim = {
    userAgent: ua,
    appVersion: ua.replace(/^Mozilla\//, ''),
    appName: 'Netscape',
    appCodeName: 'Mozilla',
    product: 'Gecko',
    productSub: '20030107',
    platform: 'MacIntel',
    vendor: 'Google Inc.',
    vendorSub: '',
    language: 'en-US',
    languages: ['en-US', 'en'],
    hardwareConcurrency: 6,
    deviceMemory: 4,
    maxTouchPoints: 0,
    webdriver: false,
    cookieEnabled: true,
    onLine: true,
    doNotTrack: null,
    pdfViewerEnabled: true,
    plugins: [],
    mimeTypes: [],
    permissions: { query: async () => ({ state: 'prompt', onchange: null }) },
    sendBeacon: () => true,
    javaEnabled: () => false,
    getBattery: async () => ({ charging: true, level: 1, chargingTime: 0, dischargingTime: Infinity })
  };

  const document = new Document();
  const assign = (name, value) => {
    if (typeof g[name] === 'undefined') {
      Object.defineProperty(g, name, { value, writable: true, configurable: true });
    }
  };

  // Make the global object behave like a Window event target.
  const windowEvents = new ET();
  assign('addEventListener', windowEvents.addEventListener.bind(windowEvents));
  assign('removeEventListener', windowEvents.removeEventListener.bind(windowEvents));
  assign('dispatchEvent', windowEvents.dispatchEvent.bind(windowEvents));

  assign('window', g);
  assign('top', g);
  assign('parent', g);
  assign('frames', g);
  assign('document', document);
  assign('navigator', navigatorShim);
  assign('location', location);
  assign('origin', 'https://www.youtube.com');
  assign('isSecureContext', true);
  assign('screen', { width: 1920, height: 1080, availWidth: 1920, availHeight: 1050, colorDepth: 24, pixelDepth: 24, orientation: { type: 'landscape-primary', angle: 0 } });
  assign('innerWidth', 1920);
  assign('innerHeight', 947);
  assign('outerWidth', 1920);
  assign('outerHeight', 1050);
  assign('devicePixelRatio', 1);
  assign('screenX', 0);
  assign('screenY', 0);
  assign('scrollX', 0);
  assign('scrollY', 0);
  assign('pageXOffset', 0);
  assign('pageYOffset', 0);
  assign('localStorage', new ShimStorage());
  assign('sessionStorage', new ShimStorage());
  assign('history', { length: 1, state: null, pushState() {}, replaceState() {}, back() {}, forward() {}, go() {} });
  assign('getComputedStyle', () => new Proxy({}, { get: (t, p) => (p === 'getPropertyValue' ? () => '' : '') }));
  assign('requestAnimationFrame', (cb) => setTimeout(() => cb(g.performance.now()), 16));
  assign('cancelAnimationFrame', (id) => clearTimeout(id));
  assign('requestIdleCallback', (cb) => setTimeout(() => cb({ didTimeout: false, timeRemaining: () => 16 }), 1));
  assign('cancelIdleCallback', (id) => clearTimeout(id));
  assign('matchMedia', (query) => ({
    matches: false, media: String(query), onchange: null,
    addListener() {}, removeListener() {}, addEventListener() {}, removeEventListener() {}, dispatchEvent() { return true; }
  }));
  assign('Node', Node);
  assign('Element', Element);
  assign('HTMLElement', HTMLElement);
  assign('HTMLDivElement', HTMLDivElement);
  assign('HTMLScriptElement', HTMLScriptElement);
  assign('HTMLCanvasElement', HTMLCanvasElement);
  assign('HTMLIFrameElement', HTMLIFrameElement);
  assign('HTMLImageElement', HTMLImageElement);
  assign('HTMLVideoElement', HTMLVideoElement);
  assign('Image', HTMLImageElement);
  assign('Document', Document);
  assign('Text', Text);
  assign('MutationObserver', Observer);
  assign('IntersectionObserver', Observer);
  assign('ResizeObserver', Observer);
  assign('PerformanceObserver', Observer);
  assign('Storage', ShimStorage);
  assign('alert', () => {});
  assign('confirm', () => false);
  assign('prompt', () => null);
  assign('open', () => null);
  assign('close', () => {});
  assign('focus', () => {});
  assign('blur', () => {});
  assign('scrollTo', () => {});
  assign('scroll', () => {});
  assign('postMessage', () => {});
  assign('name', '');
  assign('closed', false);
  assign('length', 0);
}
