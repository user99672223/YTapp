// The bundle must load in a bare context (JavaScriptCore has no Node/Web globals) and expose
// the TubeBridge API Swift calls.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { loadBundle } from './harness.mjs';

const REQUIRED_METHODS = [
  'init', 'validateCookie', 'accountInfo', 'home', 'subscriptions', 'subscribedChannels', 'search',
  'searchSuggestions', 'channel', 'channelTab', 'playlist', 'history', 'playlists', 'more', 'videoInfo',
  'resolveFormats', 'markWatched', 'watchtime', 'shortsFeed', 'shortsMore', 'shortInfo', 'rate', 'subscribe',
  'watchLater', 'watchLaterStatus', 'comments', 'commentsMore', 'postComment', 'bundleInfo', 'sessionState'
];

test('bundle loads without any host natives', () => {
  const { context } = loadBundle({ natives: false });
  assert.equal(typeof context.TubeBridge, 'object');
  for (const name of ['URL', 'URLSearchParams', 'TextEncoder', 'TextDecoder', 'fetch', 'Headers', 'Request', 'Response',
    'AbortController', 'EventTarget', 'CustomEvent', 'setTimeout', 'queueMicrotask', 'atob', 'btoa', 'crypto', 'performance']) {
    assert.notEqual(typeof context[name], 'undefined', `${name} should be polyfilled`);
  }
});

test('bridge exposes every method Swift uses', async () => {
  const { context, call } = loadBundle();
  const methods = Array.from(context.TubeBridge.methods);
  for (const m of REQUIRED_METHODS) assert.ok(methods.includes(m), `missing ${m}`);
  const info = await call('bundleInfo');
  assert.match(info.bundleVersion, /^\d+\.\d+\.\d+\+yt\d+\.\d+\.\d+$/);
  assert.equal(info.protocol, 1);
});

test('unknown methods and bad arguments are reported as errors', async () => {
  const { call, context } = loadBundle();
  await assert.rejects(call('doesNotExist'), (e) => e.kind === 'invalid');
  await assert.rejects(new Promise((resolve, reject) => {
    context.__native.reply = (id, err) => (err ? reject(JSON.parse(err)) : resolve());
    context.TubeBridge.call(1, 'home', '{not json');
  }), (e) => e.kind === 'invalid');
});

test('calls before init fail with noSession', async () => {
  const { call } = loadBundle();
  await assert.rejects(call('home'), (e) => e.kind === 'noSession');
});
