// Small helpers shared by the normalizers.

export function text(value) {
  if (value == null) return undefined;
  if (typeof value === 'string') {
    const s = value.trim();
    return s && s !== 'N/A' ? s : undefined;
  }
  if (typeof value === 'number') return String(value);
  if (typeof value === 'object') {
    if (typeof value.text === 'string' && value.text.trim()) return value.text.trim();
    if (Array.isArray(value.runs)) {
      const joined = value.runs.map((r) => (r && typeof r.text === 'string' ? r.text : '')).join('').trim();
      if (joined) return joined;
    }
    if (typeof value.toString === 'function' && value.toString !== Object.prototype.toString) {
      const s = String(value.toString()).trim();
      if (s && s !== 'N/A' && s !== '[object Object]') return s;
    }
    if (value.content && typeof value.content === 'string') return value.content.trim() || undefined;
  }
  return undefined;
}

export function fixUrl(url) {
  if (!url || typeof url !== 'string') return undefined;
  if (url.startsWith('//')) return 'https:' + url;
  if (url.startsWith('http://')) return 'https://' + url.slice(7);
  return url;
}

// Picks the largest thumbnail whose width <= maxWidth (or the smallest one above it).
export function bestThumb(thumbs, maxWidth = 1280) {
  if (!thumbs) return undefined;
  if (!Array.isArray(thumbs)) {
    if (Array.isArray(thumbs.thumbnails)) thumbs = thumbs.thumbnails;
    else if (Array.isArray(thumbs.image)) thumbs = thumbs.image;
    else if (thumbs.url) thumbs = [thumbs];
    else return undefined;
  }
  const list = thumbs.filter((t) => t && typeof t.url === 'string');
  if (!list.length) return undefined;
  let best = null;
  for (const t of list) {
    const w = Number(t.width) || 0;
    if (w <= maxWidth && (!best || w > (Number(best.width) || 0))) best = t;
  }
  if (!best) {
    best = list.reduce((a, b) => ((Number(a.width) || 0) <= (Number(b.width) || 0) ? a : b));
  }
  return fixUrl(best.url);
}

export function videoThumb(id) {
  return id ? `https://i.ytimg.com/vi/${id}/hqdefault.jpg` : undefined;
}

// Feeds keep serving the "…_live.jpg" frame captured while a stream was on air (YouTube's red LIVE
// label is baked into it) after the stream ended. For an item that is not live, use the regular
// thumbnail instead; hqdefault is the one variant every video has.
export function notLiveThumb(url, id) {
  if (typeof url === 'string' && id && /\/vi(?:_webp)?\/[\w-]+\/[\w-]+_live\.(?:jpg|webp)(?:[?#]|$)/.test(url)) {
    return videoThumb(id);
  }
  return url;
}

export function parseDuration(str) {
  if (!str || typeof str !== 'string') return undefined;
  const m = str.trim().match(/^(\d+)(?::(\d{1,2}))?(?::(\d{1,2}))?$/);
  if (!m) return undefined;
  const parts = str.trim().split(':').map((p) => parseInt(p, 10));
  if (parts.some((p) => Number.isNaN(p))) return undefined;
  return parts.reduce((acc, p) => acc * 60 + p, 0);
}

export function isDurationText(str) {
  return typeof str === 'string' && /^\d+(:\d{2}){1,2}$/.test(str.trim());
}

export function clean(obj) {
  if (Array.isArray(obj)) return obj.map(clean);
  if (obj && typeof obj === 'object') {
    const out = {};
    for (const [k, v] of Object.entries(obj)) {
      if (v === undefined || v === null || (typeof v === 'number' && Number.isNaN(v))) continue;
      out[k] = clean(v);
    }
    return out;
  }
  return obj;
}

export function endpointBrowseId(endpoint) {
  const p = endpoint?.payload;
  if (!p) return undefined;
  return p.browseId || p.channelId || undefined;
}

export function endpointVideoId(endpoint) {
  const p = endpoint?.payload;
  if (!p) return undefined;
  return p.videoId || (Array.isArray(p.videoIds) ? p.videoIds[0] : undefined) || undefined;
}

export function isChannelId(id) {
  return typeof id === 'string' && /^UC[\w-]{22}$/.test(id);
}

export function nodeType(node) {
  return node && typeof node === 'object' ? node.type || node.constructor?.type : undefined;
}

// Decodes the protobuf-encoded entity keys YouTube uses in frameworkUpdates mutations and
// returns every length-delimited string field (video ids, channel ids ...).
export function entityKeyStrings(key) {
  const out = [];
  if (!key || typeof key !== 'string') return out;
  let bytes;
  try {
    const b64 = decodeURIComponent(key).replace(/-/g, '+').replace(/_/g, '/');
    const bin = atob(b64.padEnd(b64.length + ((4 - (b64.length % 4)) % 4), '='));
    bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  } catch {
    return out;
  }
  let i = 0;
  const readVarint = () => {
    let result = 0;
    let shift = 0;
    while (i < bytes.length) {
      const b = bytes[i++];
      result += (b & 0x7f) * Math.pow(2, shift);
      if ((b & 0x80) === 0) break;
      shift += 7;
    }
    return result;
  };
  while (i < bytes.length) {
    const tag = readVarint();
    const wire = tag & 7;
    if (wire === 0) readVarint();
    else if (wire === 1) i += 8;
    else if (wire === 5) i += 4;
    else if (wire === 2) {
      const len = readVarint();
      const slice = bytes.subarray(i, i + len);
      i += len;
      let s = '';
      let printable = true;
      for (const b of slice) {
        if (b < 0x20 || b > 0x7e) {
          printable = false;
          break;
        }
        s += String.fromCharCode(b);
      }
      if (printable && s) out.push(s);
    } else {
      break;
    }
  }
  return out;
}
