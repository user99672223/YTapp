// Error classification shared with Swift (Core/Bridge/BridgeError.swift decodes this shape).

export class BridgeError extends Error {
  constructor(kind, message, detail) {
    super(message);
    this.name = 'BridgeError';
    this.kind = kind;
    this.detail = detail;
  }
}

export function fail(kind, message, detail) {
  throw new BridgeError(kind, message, detail);
}

function extractStatus(message) {
  const m = /status(?: code)? (\d{3})/i.exec(message) || /failed: (\d{3})/i.exec(message);
  return m ? Number(m[1]) : undefined;
}

export function classify(error) {
  if (error instanceof BridgeError) {
    return { kind: error.kind, message: error.message, detail: error.detail ? String(error.detail).slice(0, 2000) : undefined };
  }
  const message = (error && (error.message || error.reason)) ? String(error.message || error.reason) : String(error);
  let info = '';
  try {
    if (error && error.info) info = typeof error.info === 'string' ? error.info : JSON.stringify(error.info);
  } catch {
    info = '';
  }
  const status = extractStatus(message);
  const haystack = `${message} ${info}`;
  let kind = 'unknown';
  if (status === 401 || status === 403) kind = 'auth';
  else if (status === 429) kind = 'rateLimited';
  else if (status === 404) kind = 'notFound';
  else if (status && status >= 500) kind = 'network';
  else if (/Network request failed|timed out|offline|could not connect|NSURLErrorDomain|network connection/i.test(haystack)) kind = 'network';
  else if (/not a bot|confirm you/i.test(haystack)) kind = 'botCheck';
  else if (/must be signed in|sign in|login|log in/i.test(haystack)) kind = 'loginRequired';
  else if (/po ?token|botguard|integrity token/i.test(haystack)) kind = 'poToken';
  else if (/decipher|nsig|n\/sig|signature|player script|player id|player data/i.test(haystack)) kind = 'extraction';
  else if (/unavailable|private|removed|not available|copyright|terminated/i.test(haystack)) kind = 'unavailable';
  else if (/pars(e|ing)|unexpected token|JSON/i.test(haystack)) kind = 'parse';
  return {
    kind,
    message,
    detail: info ? info.slice(0, 2000) : (error && error.stack ? String(error.stack).slice(0, 2000) : undefined),
    status
  };
}
