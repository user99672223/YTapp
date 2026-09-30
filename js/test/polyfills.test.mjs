// Differential tests: the bundle's polyfills vs Node's own implementations.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { loadBundle } from './harness.mjs';

const URL_CASES = [
  ['https://www.youtube.com'],
  ['https://www.YouTube.com:443/watch?v=abc&t=10#frag'],
  ['http://example.com:8080/a/b/../c/./d?x=1 2&y=é'],
  ['/iframe_api', 'https://www.youtube.com'],
  ['/s/player/abc/player_es6.vflset/en_US/base.js', 'https://www.youtube.com'],
  ['browse?prettyPrint=false', 'https://www.youtube.com/youtubei/v1/'],
  ['../up', 'https://a.com/b/c/d'],
  ['?q=1', 'https://a.com/path?old=2#h'],
  ['#only', 'https://a.com/path?old=2'],
  ['//cdn.example.com/x.js', 'https://a.com/'],
  ['https://rr1---sn-abc.googlevideo.com/videoplayback?expire=1&ei=x&ip=1.2.3.4&sparams=expire%2Cei%2Cip&mime=video%2Fwebm&n=abc_123-&c=TVHTML5'],
  ['https://user:pa ss@host.com/p'],
  ['https://host.com/a%20b/c?d=%2F&e=+'],
  ['https://host.com/path with space/ünïcode'],
  ['data:text/plain,hello'],
  ['about:blank'],
  ['https://[::1]:8080/x'],
  ['https://host.com/a/b/c/..'],
  ['HTTPS://HOST.COM/Case?Q=V']
];

function nodeUrlParts(u) {
  return { href: u.href, protocol: u.protocol, host: u.host, hostname: u.hostname, port: u.port, pathname: u.pathname, search: u.search, hash: u.hash, origin: u.origin, username: u.username, password: u.password };
}

for (const natives of [true, false]) {
  const label = natives ? 'with natives' : 'bare';

  test(`URL parsing matches Node (${label})`, () => {
    const { evaluate } = loadBundle({ natives });
    for (const [input, base] of URL_CASES) {
      const expected = nodeUrlParts(base ? new URL(input, base) : new URL(input));
      const actual = JSON.parse(evaluate(`(() => { const u = new URL(${JSON.stringify(input)}${base ? `, ${JSON.stringify(base)}` : ''}); return JSON.stringify({ href: u.href, protocol: u.protocol, host: u.host, hostname: u.hostname, port: u.port, pathname: u.pathname, search: u.search, hash: u.hash, origin: u.origin, username: u.username, password: u.password }); })()`));
      assert.deepEqual(actual, expected, `URL(${input}${base ? `, ${base}` : ''})`);
    }
    assert.throws(() => evaluate('new URL("not a url")'));
  });

  test(`URLSearchParams matches Node (${label})`, () => {
    const { evaluate } = loadBundle({ natives });
    const script = `(() => {
      const out = [];
      const p = new URLSearchParams('?a=1&b=two+words&c=%F0%9F%98%80&a=3&empty=&flag');
      out.push(p.get('a'), p.getAll('a').join('|'), p.get('b'), p.get('c'), p.get('empty'), p.get('flag'), String(p.has('zzz')));
      p.set('a', 'x y');
      p.append('z', 'ü/?&=');
      p.delete('b');
      out.push(p.toString());
      const u = new URL('https://h.com/p?n=abc&sig=1');
      u.searchParams.set('n', 'dé f');
      u.searchParams.set('pot', 'A+B/C=');
      out.push(u.href);
      const s = new URLSearchParams({ q: 'a b', r: '1' });
      s.sort();
      out.push(s.toString(), String(s.size));
      return JSON.stringify(out);
    })()`;
    const actual = JSON.parse(evaluate(script));
    const out = [];
    const p = new URLSearchParams('?a=1&b=two+words&c=%F0%9F%98%80&a=3&empty=&flag');
    out.push(p.get('a'), p.getAll('a').join('|'), p.get('b'), p.get('c'), p.get('empty'), p.get('flag'), String(p.has('zzz')));
    p.set('a', 'x y');
    p.append('z', 'ü/?&=');
    p.delete('b');
    out.push(p.toString());
    const u = new URL('https://h.com/p?n=abc&sig=1');
    u.searchParams.set('n', 'dé f');
    u.searchParams.set('pot', 'A+B/C=');
    out.push(u.href);
    const s = new URLSearchParams({ q: 'a b', r: '1' });
    s.sort();
    out.push(s.toString(), String(s.size));
    assert.deepEqual(actual, out);
  });

  test(`TextEncoder/TextDecoder, atob/btoa (${label})`, () => {
    const { evaluate } = loadBundle({ natives });
    const samples = ['', 'hello', 'héllo wörld', '😀 emoji 🎬 and 中文', 'a'.repeat(5000) + '€'];
    for (const s of samples) {
      const bytes = JSON.parse(evaluate(`JSON.stringify(Array.from(new TextEncoder().encode(${JSON.stringify(s)})))`));
      assert.deepEqual(bytes, Array.from(Buffer.from(s, 'utf8')), `encode ${s.slice(0, 20)}`);
      const decoded = evaluate(`new TextDecoder().decode(new Uint8Array(${JSON.stringify(bytes)}))`);
      assert.equal(decoded, s);
    }
    assert.equal(evaluate('btoa("hello world!")'), Buffer.from('hello world!').toString('base64'));
    assert.equal(evaluate('atob("aGVsbG8gd29ybGQh")'), 'hello world!');
    assert.equal(evaluate('new TextDecoder().decode(new Uint8Array([0xff, 0x61]))'), '�a');
  });

  test(`SHA-1 and crypto (${label})`, () => {
    const { context, evaluate } = loadBundle({ natives });
    // Exercise the pure-JS SHA-1 even when natives exist.
    if (natives) delete context.__native.sha1Hex;
    const inputs = ['', 'abc', '1700000000 SAPISIDVALUE https://www.youtube.com', 'x'.repeat(1000), 'ünïcode',
      'The quick brown fox jumps over the lazy dog'];
    for (const input of inputs) {
      const expected = createHash('sha1').update(input, 'utf8').digest('hex');
      const actual = evaluate(`TubeBridge.debug.sha1Hex(${JSON.stringify(input)})`);
      assert.equal(actual, expected, `sha1(${input.slice(0, 20)})`);
    }
    const uuid = evaluate('crypto.randomUUID()');
    assert.match(uuid, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
    const filled = JSON.parse(evaluate('JSON.stringify(Array.from(crypto.getRandomValues(new Uint8Array(16))))'));
    assert.equal(filled.length, 16);
  });

  test(`Headers / Request / Response semantics (${label})`, async () => {
    const { evaluate } = loadBundle({ natives });
    const out = JSON.parse(evaluate(`(() => {
      const h = new Headers({ 'Content-Type': 'application/json', 'X-A': '1' });
      h.append('x-a', '2');
      h.append('Set-Cookie', 'a=1');
      h.append('Set-Cookie', 'b=2');
      const req = new Request(new URL('https://www.youtube.com/youtubei/v1/browse'), { method: 'post', body: '{"x":1}', headers: h });
      const req2 = new Request(req, { headers: { Cookie: 'SID=1' } });
      return JSON.stringify({
        get: h.get('x-a'), ct: h.get('CONTENT-TYPE'), has: h.has('missing'), cookies: h.getSetCookie(),
        entries: Array.from(h.entries()).map(([k]) => k),
        method: req.method, url: req.url, method2: req2.method, cookie2: req2.headers.get('cookie'), body2: req2._bodyText
      });
    })()`));
    assert.equal(out.get, '1, 2');
    assert.equal(out.ct, 'application/json');
    assert.equal(out.has, false);
    assert.deepEqual(out.cookies, ['a=1', 'b=2']);
    assert.deepEqual(out.entries, ['content-type', 'set-cookie', 'set-cookie', 'x-a']);
    assert.equal(out.method, 'POST');
    assert.equal(out.url, 'https://www.youtube.com/youtubei/v1/browse');
    assert.equal(out.method2, 'POST');
    assert.equal(out.cookie2, 'SID=1');
    assert.equal(out.body2, '{"x":1}');
  });
}

test('fetch goes through the native layer, supports abort and JSON hooks', async () => {
  const seen = [];
  const { context, evaluate } = loadBundle({
    router: (req) => {
      seen.push(req);
      if (req.url.includes('/slow')) return new Promise((resolve) => setTimeout(() => resolve({ status: 200, body: 'late' }), 200));
      return { status: 201, body: { ok: true, echo: req.body }, headers: { 'content-type': 'application/json', 'x-test': 'yes' } };
    }
  });
  evaluate(`globalThis.__result = null;
    fetch('https://api.example.com/echo?x=1', { method: 'POST', body: JSON.stringify({ hello: 'wörld' }), headers: { 'Content-Type': 'application/json' } })
      .then(async (r) => { globalThis.__result = { status: r.status, ok: r.ok, header: r.headers.get('x-test'), json: await r.json(), url: r.url }; })
      .catch((e) => { globalThis.__result = { error: String(e) }; });
    globalThis.__aborted = null;
    const ac = new AbortController();
    fetch('https://api.example.com/slow', { signal: ac.signal }).then(() => { globalThis.__aborted = 'resolved'; }, (e) => { globalThis.__aborted = e.name; });
    setTimeout(() => ac.abort(), 10);`);
  await new Promise((r) => setTimeout(r, 300));
  const result = context.__result;
  assert.equal(result.status, 201);
  assert.equal(result.ok, true);
  assert.equal(result.header, 'yes');
  assert.deepEqual(JSON.parse(JSON.stringify(result.json)), { ok: true, echo: '{"hello":"wörld"}' });
  assert.equal(seen[0].method, 'POST');
  assert.equal(seen[0].headers['content-type'], 'application/json');
  assert.equal(context.__aborted, 'AbortError');
});

test('timers run in order and clearTimeout cancels', async () => {
  const { context, evaluate } = loadBundle();
  evaluate(`globalThis.__order = [];
    setTimeout(() => __order.push('b'), 20);
    setTimeout(() => __order.push('a'), 5);
    const t = setTimeout(() => __order.push('never'), 10);
    clearTimeout(t);
    let n = 0; const i = setInterval(() => { __order.push('i' + n); if (++n === 3) clearInterval(i); }, 1);
    queueMicrotask(() => __order.push('micro'));`);
  await new Promise((r) => setTimeout(r, 80));
  const order = Array.from(context.__order);
  assert.equal(order[0], 'micro');
  assert.ok(order.indexOf('a') < order.indexOf('b'));
  assert.ok(!order.includes('never'));
  assert.deepEqual(order.filter((x) => x.startsWith('i')), ['i0', 'i1', 'i2']);
});

test('performance.now counts from timeOrigin, not from device boot', () => {
  // On the Apple TV the native clock is the system uptime (JSRuntime.swift).
  const uptimeAtLoad = 3 * 24 * 3600 * 1000;
  const { evaluate } = loadBundle({ overrides: { now: () => uptimeAtLoad + performance.now() } });
  const now = evaluate('performance.now()');
  assert.ok(now >= 0 && now < 5000, `performance.now() is ${now}`);
  assert.ok(Math.abs(evaluate('performance.timeOrigin + performance.now()') - Date.now()) < 5000);
});
