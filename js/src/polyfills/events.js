// Event, CustomEvent, EventTarget, DOMException, AbortController, AbortSignal.

export class DOMException extends Error {
  constructor(message = '', name = 'Error') {
    super(message);
    this.name = name;
  }
  get code() {
    return { AbortError: 20, TimeoutError: 23, NotFoundError: 8, InvalidStateError: 11 }[this.name] || 0;
  }
}

export class Event {
  constructor(type, init = {}) {
    if (arguments.length === 0) throw new TypeError('Event type is required');
    this.type = String(type);
    this.bubbles = !!init.bubbles;
    this.cancelable = !!init.cancelable;
    this.composed = !!init.composed;
    this.defaultPrevented = false;
    this.timeStamp = Date.now();
    this.target = null;
    this.currentTarget = null;
    this.isTrusted = false;
    this._stop = false;
  }
  preventDefault() {
    if (this.cancelable) this.defaultPrevented = true;
  }
  stopPropagation() {}
  stopImmediatePropagation() {
    this._stop = true;
  }
  composedPath() {
    return this.target ? [this.target] : [];
  }
}

export class CustomEvent extends Event {
  constructor(type, init = {}) {
    super(type, init);
    this.detail = init.detail === undefined ? null : init.detail;
  }
}

export class EventTarget {
  constructor() {
    Object.defineProperty(this, '_listeners', { value: new Map(), enumerable: false, writable: true });
  }

  _getListeners() {
    if (!this._listeners) Object.defineProperty(this, '_listeners', { value: new Map(), enumerable: false });
    return this._listeners;
  }

  addEventListener(type, listener, options) {
    if (!listener) return;
    const once = typeof options === 'object' && options !== null && !!options.once;
    const signal = typeof options === 'object' && options !== null ? options.signal : undefined;
    const map = this._getListeners();
    const list = map.get(type) || [];
    if (list.some((entry) => entry.listener === listener)) return;
    const entry = { listener, once };
    list.push(entry);
    map.set(type, list);
    if (signal) {
      signal.addEventListener('abort', () => this.removeEventListener(type, listener), { once: true });
    }
  }

  removeEventListener(type, listener) {
    const map = this._getListeners();
    const list = map.get(type);
    if (!list) return;
    const index = list.findIndex((entry) => entry.listener === listener);
    if (index !== -1) list.splice(index, 1);
  }

  dispatchEvent(event) {
    if (!(event && typeof event.type === 'string')) throw new TypeError('Argument must be an Event');
    try {
      event.target = event.target || this;
    } catch { /* read-only target on foreign events */ }
    try {
      event.currentTarget = this;
    } catch { /* ignore */ }
    const handlerName = 'on' + event.type;
    const list = (this._getListeners().get(event.type) || []).slice();
    const invoke = (listener) => {
      try {
        if (typeof listener === 'function') listener.call(this, event);
        else if (listener && typeof listener.handleEvent === 'function') listener.handleEvent(event);
      } catch (error) {
        (globalThis.reportError || ((e) => console.error(e)))(error);
      }
    };
    if (typeof this[handlerName] === 'function') invoke(this[handlerName]);
    for (const entry of list) {
      if (entry.once) this.removeEventListener(event.type, entry.listener);
      invoke(entry.listener);
      if (event._stop) break;
    }
    return !event.defaultPrevented;
  }
}

export class AbortSignal extends EventTarget {
  constructor() {
    super();
    this.aborted = false;
    this.reason = undefined;
    this.onabort = null;
  }

  throwIfAborted() {
    if (this.aborted) throw this.reason;
  }

  _abort(reason) {
    if (this.aborted) return;
    this.aborted = true;
    this.reason = reason === undefined ? new DOMException('This operation was aborted', 'AbortError') : reason;
    this.dispatchEvent(new Event('abort'));
  }

  static abort(reason) {
    const signal = new AbortSignal();
    signal._abort(reason);
    return signal;
  }

  static timeout(ms) {
    const signal = new AbortSignal();
    setTimeout(() => signal._abort(new DOMException('The operation timed out.', 'TimeoutError')), ms);
    return signal;
  }

  static any(signals) {
    const signal = new AbortSignal();
    for (const s of signals) {
      if (s.aborted) {
        signal._abort(s.reason);
        return signal;
      }
      s.addEventListener('abort', () => signal._abort(s.reason), { once: true });
    }
    return signal;
  }
}

export class AbortController {
  constructor() {
    this.signal = new AbortSignal();
  }
  abort(reason) {
    this.signal._abort(reason);
  }
}
