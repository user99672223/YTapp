// End-to-end bridge test against the fake YouTube: session + player analysis, feeds with
// continuation, watch info, deciphering, history pings, Shorts and actions. The normalized DTOs
// are written to Packages/Core/Tests/CoreTests/Fixtures so the Swift tests decode real output.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { writeFileSync, mkdirSync } from 'node:fs';
import { loadBundle } from './harness.mjs';
import { createFakeYouTube, COOKIE, CH1, CH2, PLAYER_ID } from './fakeyt.mjs';

const fixturesDir = new URL('../../Packages/Core/Tests/CoreTests/Fixtures/', import.meta.url);
mkdirSync(fixturesDir, { recursive: true });
const writeFixture = (name, value) => writeFileSync(new URL(name, fixturesDir), JSON.stringify(value, null, 2) + '\n');

async function connected() {
  const yt = createFakeYouTube();
  const bundle = loadBundle({ router: yt.router });
  const session = await bundle.call('init', { cookie: COOKIE, client: 'TV' });
  return { ...bundle, yt, session };
}

test('init creates a signed-in session, analyses the player and caches it', async () => {
  const { session, cache, yt, logs } = await connected();
  assert.equal(session.loggedIn, true, JSON.stringify(logs.slice(-5)));
  assert.equal(session.playerId, PLAYER_ID);
  assert.equal(session.hasDecipher, true);
  assert.equal(session.signatureTimestamp, 20314);
  assert.equal(session.account.name, 'Test Household');
  assert.equal(session.account.handle, '@testhousehold');
  assert.ok(cache.has(PLAYER_ID), 'deciphered player is persisted through the native cache');
  assert.ok(cache.has('innertube_session_data'));
  const accountHit = yt.hits.find((h) => h.path === '/youtubei/v1/account/accounts_list');
  assert.match(accountHit.headers.authorization, /^SAPISIDHASH \d+_[0-9a-f]{40}$/);
  assert.ok(accountHit.headers.cookie.includes('SAPISID=sapisid123/abc'));
  writeFixture('session.json', session);

  // A second session reuses the cached player (no base.js download).
  const again = loadBundle({ router: yt.router });
  for (const [k, v] of cache) again.cache.set(k, v);
  const before = yt.hits.filter((h) => h.path.endsWith('/base.js')).length;
  const s2 = await again.call('init', { cookie: COOKIE, client: 'TV' });
  assert.equal(s2.hasDecipher, true);
  assert.equal(yt.hits.filter((h) => h.path.endsWith('/base.js')).length, before);
});

test('validateCookie reports the account or a clear auth error', async () => {
  const yt = createFakeYouTube();
  const { call } = loadBundle({ router: yt.router });
  const account = await call('validateCookie', { cookie: COOKIE });
  assert.equal(account.name, 'Test Household');
  await assert.rejects(call('validateCookie', { cookie: 'foo=bar' }), (e) => e.kind === 'auth');
  await assert.rejects(call('validateCookie', { cookie: '' }), (e) => e.kind === 'invalid');
});

test('home feed normalizes legacy, lockup and Shorts items, with continuation', async () => {
  const { call } = await connected();
  const home = await call('home');
  writeFixture('home.json', home);
  const all = home.sections.flatMap((s) => s.items);
  const first = all.find((i) => i.id === 'VIDEOID0001');
  assert.equal(first.title, 'First video');
  assert.equal(first.channelId, CH1);
  assert.equal(first.channelName, 'Channel One');
  assert.equal(first.durationText, '10:05');
  assert.equal(first.durationSeconds, 605);
  assert.equal(first.watchedPercent, 40);
  const lock = all.find((i) => i.id === 'LOCKUPVID01');
  assert.equal(lock.title, 'Lockup video');
  assert.equal(lock.channelId, CH2);
  assert.equal(lock.durationSeconds, 3723);
  assert.equal(lock.viewCountText, '1.2M views');
  assert.equal(lock.publishedText, '2 weeks ago');
  const shorts = home.sections.find((s) => s.style === 'shorts');
  assert.ok(shorts, 'Shorts shelf becomes its own section');
  assert.deepEqual(shorts.items.map((i) => i.id), ['SHORTID0001', 'SHORTID0002']);
  assert.ok(home.continuation, 'has continuation');
  const more = await call('more', { key: home.continuation });
  assert.equal(more.sections[0].items[0].id, 'VIDEOID0003');
  writeFixture('home-more.json', more);
});

test('video info, deciphering, history and watch-time pings', async () => {
  const { call, yt } = await connected();
  const details = await call('videoInfo', { id: 'VIDEOID0001', client: 'TV' });
  writeFixture('video.json', details);
  assert.equal(details.title, 'First video');
  assert.equal(details.channel.id, CH1);
  assert.equal(details.channel.isSubscribed, true);
  assert.equal(details.channel.subscriberCountText, '1.5M subscribers');
  assert.deepEqual(details.chapters.map((c) => [c.title, c.startSeconds]), [['Intro', 0], ['Part one', 60]]);
  assert.equal(details.captions.length, 2);
  assert.match(details.captions[0].url, /[?&]fmt=vtt(&|$)/);
  assert.equal(details.captions[1].isAuto, true);
  assert.deepEqual(details.upNext.map((v) => v.id), ['RELATEDVID1', 'RELATEDVID2']);
  assert.equal(details.autoplayNextId, 'RELATEDVID1');
  assert.equal(details.playerClient, 'TV');
  assert.match(details.userAgent, /Cobalt/);
  const hdr = details.formats.find((f) => f.itag === 337);
  assert.equal(hdr.isHdr, true);
  assert.equal(details.formats.find((f) => f.itag === 313).isHdr, false);
  assert.equal(details.formats.find((f) => f.itag === 251).codecs, 'opus');
  const playerHit = yt.hits.find((h) => h.path === '/youtubei/v1/player');
  assert.equal(playerHit.body.context.client.clientName, 'TVHTML5');
  assert.equal(playerHit.body.playbackContext.contentPlaybackContext.signatureTimestamp, 20314);

  const idx = (itag) => details.formats.find((f) => f.itag === itag).index;
  const resolved = await call('resolveFormats', { id: 'VIDEOID0001', indices: [idx(401), idx(251)] });
  const videoUrl = new URL(resolved.urls[String(idx(401))]);
  assert.equal(videoUrl.hostname, 'rr1---sn-fake.googlevideo.com');
  assert.equal(videoUrl.searchParams.get('sig'), 'ZYXGIS');
  assert.equal(videoUrl.searchParams.get('n'), 'bcdefa_ok');
  assert.equal(videoUrl.searchParams.get('itag'), '401');
  assert.equal(videoUrl.searchParams.get('mime'), 'video/webm');
  assert.match(resolved.userAgent, /Cobalt/);

  const watched = await call('markWatched', { id: 'VIDEOID0001' });
  assert.equal(watched.ok, true);
  const playback = yt.hits.find((h) => h.path === '/api/stats/playback');
  const pq = new URL(playback.url).searchParams;
  assert.equal(new URL(playback.url).hostname, 'www.youtube.com');
  assert.equal(pq.get('docid'), 'VIDEOID0001');
  assert.equal(pq.get('ver'), '2');
  assert.equal(pq.get('cpn'), watched.cpn);
  assert.equal(pq.get('c'), 'tvhtml5');
  assert.ok(playback.headers.cookie, 'history ping carries the account cookies');

  const wt = await call('watchtime', { id: 'VIDEOID0001', segments: [[0, 30.5], [45, 50]], cmt: 50, playing: true, len: 605, lact: 1200, rt: 35.5, volume: 100, fmt: 401, afmt: 251 });
  assert.equal(wt.ok, true);
  const ping = yt.hits.filter((h) => h.path === '/api/stats/watchtime').pop();
  const q = new URL(ping.url).searchParams;
  assert.equal(q.get('st'), '0.000,45.000');
  assert.equal(q.get('et'), '30.500,50.000');
  assert.equal(q.get('cmt'), '50.000');
  assert.equal(q.get('state'), 'playing');
  assert.equal(q.get('cpn'), watched.cpn);
  assert.equal(q.get('fmt'), '401');
  assert.equal(q.get('final'), null);
  await call('watchtime', { id: 'VIDEOID0001', segments: [[50, 52]], cmt: 52, playing: false, final: true, len: 605, rt: 40 });
  const last = new URL(yt.hits.filter((h) => h.path === '/api/stats/watchtime').pop().url).searchParams;
  assert.equal(last.get('final'), '1');
  assert.equal(last.get('state'), 'paused');
});

test('search, suggestions and channel items', async () => {
  const { call } = await connected();
  const suggestions = await call('searchSuggestions', { query: 'que' });
  assert.deepEqual(suggestions, ['query one', 'query two']);
  const results = await call('search', { query: 'hello', filters: { upload_date: 'week', type: 'all' } });
  writeFixture('search.json', results);
  const items = results.sections.flatMap((s) => s.items);
  const channel = items.find((i) => i.type === 'channel');
  assert.equal(channel.id, CH2);
  assert.equal(channel.handle, '@channeltwo');
  assert.equal(channel.subscriberCountText, '2.1M subscribers');
  assert.equal(channel.avatar, 'https://yt3.ggpht.com/two');
  assert.equal(channel.isSubscribed, false);
  assert.ok(items.some((i) => i.id === 'SEARCHVID01'));
  assert.ok(results.sections.some((s) => s.style === 'shorts' && s.items[0].id === 'SHORTID0003'));
});

test('Shorts feed seeds from Home and resolves a short', async () => {
  const { call, yt } = await connected();
  const feed = await call('shortsFeed', {});
  assert.deepEqual(feed.ids, ['SHORTID0001', 'SHORTID0002', 'SHORTID0004']);
  assert.ok(feed.continuation);
  const short = await call('shortInfo', { id: 'SHORTID0001', client: 'TV' });
  writeFixture('short.json', short);
  assert.equal(short.title, 'Short one');
  assert.equal(short.likeStatus, 'like');
  assert.ok(short.formats.length > 0);
  const watched = await call('markWatched', { id: 'SHORTID0001' });
  assert.equal(watched.ok, true);
  assert.ok(yt.hits.some((h) => h.path === '/api/stats/playback' && h.url.includes('docid=SHORTID0001')));
});

test('actions: rate, subscribe, watch later', async () => {
  const { call, yt } = await connected();
  await call('videoInfo', { id: 'VIDEOID0001', client: 'TV' });
  assert.deepEqual(await call('rate', { id: 'VIDEOID0001', rating: 'like' }), { likeStatus: 'like' });
  // YouTube.js' InteractionManager uses the TV client, which takes the video id as `target`.
  assert.ok(yt.hits.some((h) => h.path === '/youtubei/v1/like/like' &&
    (h.body.target === 'VIDEOID0001' || h.body.target?.videoId === 'VIDEOID0001')));
  assert.deepEqual(await call('subscribe', { channelId: CH2, subscribe: true }), { isSubscribed: true });
  assert.ok(yt.hits.some((h) => h.path === '/youtubei/v1/subscription/subscribe' && h.body.channelIds[0] === CH2));
  assert.deepEqual(await call('watchLater', { id: 'VIDEOID0001', add: true }), { inWatchLater: true });
  const edit = yt.hits.find((h) => h.path === '/youtubei/v1/browse/edit_playlist');
  assert.equal(edit.body.playlistId, 'WL');
  assert.equal(edit.body.actions[0].addedVideoId, 'VIDEOID0001');
});

test('subscribed channels come from the channels page, else from the guide', async () => {
  const { call } = await connected();
  const direct = await call('subscribedChannels');
  const items = direct.sections.flatMap((s) => s.items);
  assert.deepEqual(items.map((i) => [i.type, i.id, i.name]), [['channel', CH1, 'Channel One'], ['channel', CH2, 'Channel Two']]);

  const yt = createFakeYouTube({ channelsFeed: 'broken' });
  const bundle = loadBundle({ router: yt.router });
  await bundle.call('init', { cookie: COOKIE, client: 'TV' });
  const fallback = await bundle.call('subscribedChannels');
  const guide = fallback.sections.flatMap((s) => s.items);
  assert.deepEqual(guide.map((i) => [i.type, i.id, i.name]), [['channel', CH1, 'Channel One'], ['channel', CH2, 'Channel Two']]);
  assert.match(guide[0].avatar, /^https:\/\/yt3\.ggpht\.com\/.*=s240-/);
  assert.equal(guide[0].isSubscribed, true);
  assert.equal(fallback.continuation, undefined);
  assert.ok(yt.hits.some((h) => h.path === '/youtubei/v1/guide'));
});

test('a rejected stream client falls back to the next one and is remembered', async () => {
  const yt = createFakeYouTube({ rejectClients: ['TVHTML5'] });
  const bundle = loadBundle({ router: yt.router });
  await bundle.call('init', { cookie: COOKIE, client: 'TV' });
  const details = await bundle.call('videoInfo', { id: 'VIDEOID0001', client: 'TV' });
  assert.equal(details.playerClient, 'WEB_EMBEDDED');
  const players = () => yt.hits.filter((h) => h.path === '/youtubei/v1/player').map((h) => h.body.context.client.clientName);
  assert.deepEqual(players(), ['TVHTML5', 'TVHTML5', 'WEB_EMBEDDED_PLAYER']);
  assert.ok(bundle.logs.some((l) => /stream client TV failed: \[extraction 400\]/.test(l.message)), 'each failed client is logged');
  const resolved = await bundle.call('resolveFormats', { id: 'VIDEOID0001', indices: [details.formats.find((f) => f.itag === 251).index] });
  const url = new URL(Object.values(resolved.urls)[0]);
  assert.equal(url.searchParams.get('pot'), null, 'no PO token on clients that need none');
  // The rejected client is skipped for the rest of the session.
  const short = await bundle.call('shortInfo', { id: 'SHORTID0001', client: 'TV' });
  assert.equal(short.playerClient, 'WEB_EMBEDDED');
  assert.deepEqual(players().slice(3), ['WEB_EMBEDDED_PLAYER']);
});

test('automatic client is the 5.x TV app identity; all clients failing gives one clear error', async () => {
  const { call, yt } = await connected();
  const auto = await call('videoInfo', { id: 'VIDEOID0001', client: 'AUTO' });
  assert.equal(auto.playerClient, 'TV');
  const hits = yt.hits.filter((h) => h.path === '/youtubei/v1/player');
  assert.equal(hits.length, 1);
  const client = hits[0].body.context.client;
  assert.equal(client.clientName, 'TVHTML5');
  assert.equal(client.clientVersion, '5.20260707');
  assert.equal(client.browserName, undefined);
  assert.match(hits[0].headers['user-agent'], /Cobalt/);
  assert.equal(hits[0].headers['x-youtube-client-version'], '5.20260707');
  const resolved = await call('resolveFormats', { id: 'VIDEOID0001', indices: [auto.formats.find((f) => f.itag === 401).index] });
  assert.equal(new URL(Object.values(resolved.urls)[0]).searchParams.get('cver'), '5.20260707');

  const all = createFakeYouTube({ rejectClients: ['TVHTML5', 'WEB_EMBEDDED_PLAYER', 'MWEB'] });
  const bundle = loadBundle({ router: all.router });
  await bundle.call('init', { cookie: COOKIE, client: 'AUTO' });
  await assert.rejects(bundle.call('videoInfo', { id: 'VIDEOID0001' }), (e) =>
    e.kind === 'extraction' && /No stream client could play this video/.test(e.message) &&
    /TV: \[extraction 400\]/.test(e.detail) && /WEB_EMBEDDED: \[extraction 400\]/.test(e.detail));
});

test('"The page needs to be reloaded" switches the TV client to the Samsung identity', async () => {
  const yt = createFakeYouTube({ tvReload: true });
  const bundle = loadBundle({ router: yt.router });
  await bundle.call('init', { cookie: COOKIE, client: 'AUTO' });
  const details = await bundle.call('videoInfo', { id: 'VIDEOID0001' });
  assert.equal(details.playerClient, 'TV_TIZEN');
  assert.match(details.userAgent, /Tizen/);
  const players = yt.hits.filter((h) => h.path === '/youtubei/v1/player');
  assert.equal(players.length, 2);
  assert.equal(players[1].body.context.client.deviceMake, 'Samsung');
  assert.match(players[1].headers['user-agent'], /Tizen/);
  // The next video starts with the identity that worked.
  await bundle.call('videoInfo', { id: 'VIDEOID0002' });
  assert.equal(yt.hits.filter((h) => h.path === '/youtubei/v1/player').length, 3);
  const watched = await bundle.call('markWatched', { id: 'VIDEOID0001' });
  assert.equal(watched.ok, true);
});

test('errors are classified for Swift', async () => {
  const { call } = await connected();
  await assert.rejects(call('resolveFormats', { id: 'NOTLOADED01', indices: [0] }), (e) => e.kind === 'expired');
  await assert.rejects(call('more', { key: 'nope:1' }), (e) => e.kind === 'expired');
  await assert.rejects(call('search', { query: '   ' }), (e) => e.kind === 'invalid');
});

test('an age gate is shown with YouTube\'s reason, not as a bot check', async () => {
  const { call } = await connected();
  await assert.rejects(call('videoInfo', { id: 'AGEGATED001', client: 'TV' }), (e) =>
    e.kind === 'loginRequired' && /confirm your age/.test(e.message));
  await assert.rejects(call('videoInfo', { id: 'BOTCHECK001', client: 'TV' }), (e) => e.kind === 'botCheck');
});

test('a deleted video stops at the first client with YouTube\'s reason', async () => {
  const { call, yt } = await connected();
  await assert.rejects(call('videoInfo', { id: 'DELETED0001', client: 'TV' }), (e) =>
    e.kind === 'unavailable' && /removed by the uploader/.test(e.message));
  assert.equal(yt.hits.filter((h) => h.path === '/youtubei/v1/player').length, 1);
});
