// Access to the host's native layer (Swift in the app, a Node harness in tests).
//
// The host installs `globalThis.__native` before evaluating the bundle. Every function is
// optional: when missing, the polyfills fall back to pure-JS implementations so the bundle can
// still load in a bare context (the Node smoke test exercises both modes).
//
// Host -> JS callbacks are plain globals so the host never has to retain JS function objects:
//   __tubeTimerFire(id)
//   __tubeFetchDone(id, error, status, statusText, finalUrl, headersJSON, bodyBytes)

export function nativeFn(name) {
  const n = globalThis.__native;
  const fn = n && n[name];
  return typeof fn === 'function' ? fn.bind(n) : null;
}

export function hasNative(name) {
  return nativeFn(name) !== null;
}
