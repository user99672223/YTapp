// End-to-end bridge test against the fake YouTube: session + player analysis, feeds with
// continuation, watch info, deciphering, history pings, Shorts and actions. The normalized DTOs
// are written to Packages/Core/Tests/CoreTests/Fixtures so the Swift tests decode real output.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { writeFileSync, mkdirSync } from 'node:fs';
import { loadBundle } from './harness.mjs';
import { createFakeYouTube, COOKIE, CH1, CH2, CH3, PLAYER_ID, COMMENT_IDS } from './fakeyt.mjs';

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
  // The Mix of this video opens this very video: it is not "up next" and not the autoplay pick.
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
  const resolved = await call('resolveFormats', { id: 'VIDEOID0001', indices: [idx(401), idx(251)], itags: [401, 251] });
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

  // A Mix has no playlist page: it opens its first video.
  const mix = items.find((i) => i.title === 'Mix – Channel One');
  assert.equal(mix.type, 'video');
  assert.equal(mix.id, 'MIXSEEDVID1');
  assert.ok(!items.some((i) => i.id === 'RDMIXSEEDVID1'));
  const list = items.find((i) => i.id === 'PLsearchlist01');
  assert.equal(list.type, 'playlist');
  assert.equal(list.channelName, 'Channel Two');
  assert.equal(list.videoCountText, '12 videos');
  // A scheduled premiere is flagged upcoming and its "UPCOMING" label is not a duration.
  const premiere = items.find((i) => i.id === 'UPCOMINGV02');
  assert.equal(premiere.isUpcoming, true);
  assert.equal(premiere.durationText, undefined);
  assert.equal(premiere.durationSeconds, undefined);
  // Grid shelves keep their own headline.
  const grid = results.sections.find((s) => s.items.some((i) => i.id === 'SHORTID0005'));
  assert.equal(grid.title, 'Latest Shorts from Channel One');
  assert.equal(grid.style, 'shorts');
});

test('Subscriptions, subscribed channels and Library playlists load past the first page', async () => {
  const { call } = await connected();
  const subs = await call('subscriptions');
  assert.deepEqual(subs.sections.flatMap((s) => s.items).map((i) => i.id), ['SUBSVIDEO01', 'STREAMVID01', 'UPCOMINGV01', 'LIVENOWVID1']);
  assert.ok(subs.continuation);
  const moreSubs = await call('more', { key: subs.continuation });
  assert.deepEqual(moreSubs.sections.flatMap((s) => s.items).map((i) => [i.id, i.channelName, i.viewCountText, i.isLive, i.isUpcoming]),
    [['SUBSVIDEO02', 'Channel One', '7K views', false, false], ['SUBSVIDEO03', 'Bird Watching', '300 views', false, false]]);
  assert.equal(moreSubs.continuation, undefined);

  const channels = await call('subscribedChannels');
  assert.ok(channels.continuation);
  const moreChannels = await call('more', { key: channels.continuation });
  assert.deepEqual(moreChannels.sections.flatMap((s) => s.items).map((i) => [i.type, i.id, i.name]), [['channel', CH3, 'Channel Three']]);
  assert.equal(moreChannels.continuation, undefined);

  const lists = await call('playlists');
  // "Private" is a label, not the playlist's channel.
  assert.deepEqual(lists.sections.flatMap((s) => s.items).map((i) => [i.type, i.id, i.channelName, i.videoCountText]),
    [['playlist', 'PLmine000001', undefined, '3 videos'], ['playlist', 'PLother00001', 'Channel Two', '40 videos']]);
  assert.ok(lists.continuation);
  const moreLists = await call('more', { key: lists.continuation });
  // Later pages keep only playlists too (the saved Mix is left out).
  assert.deepEqual(moreLists.sections.flatMap((s) => s.items).map((i) => [i.type, i.id, i.channelName]), [['playlist', 'PLmine000002', undefined]]);
  assert.equal(moreLists.continuation, undefined);
});

test('lockups: ended streams lose the live thumbnail, upcoming and live ones are flagged', async () => {
  const { call } = await connected();
  const subs = await call('subscriptions');
  const byId = Object.fromEntries(subs.sections.flatMap((s) => s.items).map((i) => [i.id, i]));
  const video = byId.SUBSVIDEO01;
  assert.equal(video.channelName, 'Channel Two');
  assert.equal(video.channelId, CH2);
  assert.equal(video.viewCountText, '5K views');
  assert.equal(video.publishedText, '1 hour ago');

  const ended = byId.STREAMVID01;
  assert.equal(ended.isLive, false);
  assert.equal(ended.thumbnail, 'https://i.ytimg.com/vi/STREAMVID01/hqdefault.jpg');
  assert.equal(ended.publishedText, 'Streamed 13 hours ago');
  assert.equal(ended.durationText, '2:01:15');

  const upcoming = byId.UPCOMINGV01;
  assert.equal(upcoming.isUpcoming, true);
  assert.equal(upcoming.durationText, undefined);
  assert.equal(upcoming.publishedText, 'Scheduled for 10/1/26, 8:00 PM');

  const live = byId.LIVENOWVID1;
  assert.equal(live.isLive, true);
  assert.equal(live.viewCountText, '1.2K watching');
  assert.equal(live.thumbnail, 'https://i.ytimg.com/vi/LIVENOWVID1/hq720_live.jpg');
});

test('channel header counts, author-less channel tab lockups and a key from another launch', async () => {
  const { call, yt } = await connected();
  const one = await call('channel', { id: CH1 });
  // The handle contains "video"; the video count is the "321 videos" part.
  assert.equal(one.channel.handle, '@videogamefan');
  assert.equal(one.channel.subscriberCountText, '1.5M subscribers');
  assert.equal(one.channel.videoCountText, '321 videos');
  assert.deepEqual(one.tabs, ['videos']);

  const videos = await call('channelTab', { key: one.key, id: CH1, tab: 'videos' });
  assert.deepEqual(videos.sections.flatMap((s) => s.items).map((i) => [i.id, i.channelName, i.viewCountText, i.publishedText]),
    [['ONEVIDEO01', undefined, '1.2M views', '3 days ago'], ['ONEVIDEO02', undefined, '900 views', '2 years ago']]);

  // Keys restart with every JavaScript context, so a saved key can name another channel's entry.
  const other = await call('channelTab', { key: one.key, id: CH2, tab: 'videos' });
  assert.deepEqual(other.sections.flatMap((s) => s.items).map((i) => i.id), ['TWOVIDEO01', 'TWOVIDEO02']);
  assert.ok(yt.hits.some((h) => h.path === '/youtubei/v1/browse' && h.body?.browseId === CH2));
});

test('Watch Later rows show views and age; removing a video is one request', async () => {
  const { call, yt } = await connected();
  const wl = await call('playlist', { id: 'WL' });
  const row = wl.page.sections[0].items[0];
  assert.equal(row.id, 'VIDEOID0001');
  assert.equal(row.channelName, 'Channel One');
  assert.equal(row.durationText, '4:20');
  assert.equal(row.viewCountText, '1.2M views');
  assert.equal(row.publishedText, '3 years ago');
  assert.equal(row.setVideoId, 'SETVIDEOID0001');

  const before = yt.hits.length;
  assert.deepEqual(await call('watchLater', { id: 'VIDEOID0002', add: false }), { inWatchLater: false });
  const hits = yt.hits.slice(before).filter((h) => h.path.startsWith('/youtubei/v1/browse'));
  assert.deepEqual(hits.map((h) => h.path), ['/youtubei/v1/browse/edit_playlist'], 'no paging through the list');
  assert.equal(hits[0].body.playlistId, 'WL');
  assert.deepEqual(hits[0].body.actions, [{ action: 'ACTION_REMOVE_VIDEO_BY_VIDEO_ID', removedVideoId: 'VIDEOID0002' }]);

  // A 200 answer whose status is not STATUS_SUCCEEDED is a failure, not a silent success.
  const failing = createFakeYouTube({ editPlaylist: 'failed' });
  const bundle = loadBundle({ router: failing.router });
  await bundle.call('init', { cookie: COOKIE, client: 'TV' });
  await assert.rejects(bundle.call('watchLater', { id: 'VIDEOID0002', add: false }), (e) => e.kind === 'action' && /Remove from Watch Later failed/.test(e.message));
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

test('Shorts show like and comment counts and the channel avatar from the reel overlay', async () => {
  const { call, logs } = await connected();
  // Renderers: the like count as a number (formatted like the watch page's), the comment count
  // from the comments panel's header, the avatar closest to 176 px from the player header.
  const short = await call('shortInfo', { id: 'SHORTID0001', client: 'TV' });
  assert.equal(short.likeCountText, '12K');
  assert.equal(short.commentsCountText, '1.2K');
  assert.equal(short.channel.avatar, 'https://yt3.ggpht.com/short-avatar=s176');

  // View models: the exact like count from the button's label, the comment count from the
  // comments button's title, the avatar from the channel bar.
  const second = await call('shortInfo', { id: 'SHORTID0002', client: 'TV' });
  assert.equal(second.likeStatus, 'none');
  assert.equal(second.likeCountText, '1.5M');
  assert.equal(second.commentsCountText, '3.4K');
  assert.equal(second.channel.avatar, 'https://yt3.ggpht.com/short-two=s176');

  // No overlay: the fields are left out (Swift shows "Like", "Comments" and the initial), and
  // that is logged once.
  const bare = await call('shortInfo', { id: 'SHORTID0004', client: 'TV' });
  writeFixture('short-bare.json', bare);
  assert.equal(bare.likeCountText, undefined);
  assert.equal(bare.commentsCountText, undefined);
  assert.equal(bare.channel.avatar, undefined);
  assert.equal(bare.channel.name, 'Channel One');
  assert.ok(bare.formats.length > 0);
  assert.equal(logs.filter((l) => /short SHORTID0004: the reel answer has no likeCountText, commentsCountText, avatar/.test(l.message)).length, 1);
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

test('comments: pages with a count, markers and counts, and the section key for replies', async () => {
  const { call, yt } = await connected();
  const page = await call('comments', { videoId: 'VIDEOID0001' });
  writeFixture('comments.json', page);
  assert.equal(page.countText, '1,234', 'the number of the header, without the word');
  assert.match(page.key, /^comments:\d+$/);
  assert.equal(page.continuation, page.key);
  assert.deepEqual(page.items.map((c) => c.id), [COMMENT_IDS.pinned, COMMENT_IDS.plain, COMMENT_IDS.busy]);
  const [pinned, plain, busy] = page.items;
  assert.equal(pinned.author, '@channelone');
  assert.equal(pinned.text, 'Thanks for watching!\nChapters are in the description.');
  assert.equal(pinned.publishedText, '1 day ago');
  assert.equal(pinned.likeCountText, '1.2K');
  assert.equal(pinned.replyCountText, '2');
  assert.equal(pinned.isPinned, true);
  assert.equal(pinned.isCreator, true);
  assert.equal(pinned.isHearted, true);
  assert.equal(pinned.hasReplies, true);
  assert.equal(pinned.authorAvatar, `https://yt3.ggpht.com/avatar-${COMMENT_IDS.pinned.toLowerCase()}=s176-c-k-c0x00ffffff-no-rj`);
  // No likes or replies: no "0" labels.
  assert.equal(plain.likeCountText, undefined);
  assert.equal(plain.replyCountText, undefined);
  assert.equal(plain.hasReplies, false);
  assert.equal(plain.isPinned, false);
  assert.equal(busy.hasReplies, true);
  const commentRequest = yt.hits.find((h) => h.path === '/youtubei/v1/next' && h.body?.continuation);
  assert.ok(commentRequest, 'comments come from the watch-next continuation');

  const more = await call('commentsMore', { key: page.continuation });
  writeFixture('comments-more.json', more);
  assert.equal(more.key, page.key);
  assert.equal(more.continuation, undefined);
  assert.equal(more.countText, '1,234', 'later pages keep the header');
  // YouTube repeats the pinned comment; Swift drops it (CommentsPage.append).
  assert.deepEqual(more.items.map((c) => c.id), [COMMENT_IDS.pinned, COMMENT_IDS.later, COMMENT_IDS.answered]);
  assert.deepEqual(await call('commentsMore', { key: page.key }), { key: page.key, items: [] });
});

test('comments turned off give a plain message, not a parser error', async () => {
  const yt = createFakeYouTube({ commentsOff: true });
  const { call } = loadBundle({ router: yt.router });
  await call('init', { cookie: COOKIE, client: 'TV' });
  await assert.rejects(call('comments', { videoId: 'VIDEOID0001' }), (e) =>
    e.kind === 'notFound' && /turned off/.test(e.message));
});

test('comment replies: first batch, continuation without repeats, prepopulated threads', async () => {
  const failTokens = ['REPLIESMORE_BUSY'];
  const yt = createFakeYouTube({ failTokens });
  const { call } = loadBundle({ router: yt.router });
  await call('init', { cookie: COOKIE, client: 'TV' });
  const page = await call('comments', { videoId: 'VIDEOID0001' });
  const nextHits = () => yt.hits.filter((h) => h.path === '/youtubei/v1/next').length;

  const replies = await call('commentReplies', { key: page.key, commentId: COMMENT_IDS.busy });
  writeFixture('comment-replies.json', replies);
  assert.equal(replies.commentId, COMMENT_IDS.busy);
  assert.deepEqual(replies.items.map((r) => r.id), [`${COMMENT_IDS.busy}.REPLY1`, `${COMMENT_IDS.busy}.REPLY2`]);
  assert.equal(replies.items[0].author, '@replier1');
  assert.equal(replies.items[0].text, 'Reply number 1');
  assert.equal(replies.items[0].hasReplies, false);
  assert.equal(replies.continuation, `${page.key}#${COMMENT_IDS.busy}`);

  // A failed batch stays where it was: Retry asks for the same batch again.
  await assert.rejects(call('commentRepliesMore', { key: replies.continuation }), (e) => e.kind === 'network');
  failTokens.length = 0;
  const rest = await call('commentRepliesMore', { key: replies.continuation });
  writeFixture('comment-replies-more.json', rest);
  assert.deepEqual(rest.items.map((r) => r.id), [`${COMMENT_IDS.busy}.REPLY3`], 'the repeated reply is left out');
  assert.equal(rest.continuation, undefined);
  await assert.rejects(call('commentRepliesMore', { key: replies.continuation }), (e) => e.kind === 'expired');

  const pinned = await call('commentReplies', { key: page.key, commentId: COMMENT_IDS.pinned });
  assert.deepEqual(pinned.items.map((r) => r.author), ['@replier1', '@channelone']);
  assert.equal(pinned.items[1].isCreator, true);
  assert.equal(pinned.items[0].likeCountText, '12');
  assert.equal(pinned.continuation, undefined);

  // No replies: no request.
  const before = nextHits();
  assert.deepEqual(await call('commentReplies', { key: page.key, commentId: COMMENT_IDS.plain }), { commentId: COMMENT_IDS.plain, items: [] });
  assert.equal(nextHits(), before);

  // Threads of later pages can be opened too; a reply that came with the thread needs no request.
  await call('commentsMore', { key: page.key });
  const answered = await call('commentReplies', { key: page.key, commentId: COMMENT_IDS.answered });
  assert.deepEqual(answered.items.map((r) => r.id), [`${COMMENT_IDS.answered}.REPLY1`]);
  assert.equal(answered.items[0].isCreator, true);
  assert.equal(nextHits(), before + 1, 'only the comments page was requested');

  await assert.rejects(call('commentReplies', { key: page.key, commentId: 'UgxUNKNOWN' }), (e) => e.kind === 'expired');
  await assert.rejects(call('commentReplies', { key: 'comments:999', commentId: COMMENT_IDS.busy }), (e) => e.kind === 'expired');
  await assert.rejects(call('commentRepliesMore', { key: 'nonsense' }), (e) => e.kind === 'invalid');
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

test('a stream googlevideo refuses (403) is taken from a signed-out client; history stays signed in', async () => {
  const yt = createFakeYouTube({ refuseStreams: ['TVHTML5'] });
  const bundle = loadBundle({ router: yt.router });
  await bundle.call('init', { cookie: COOKIE, client: 'AUTO' });
  const details = await bundle.call('videoInfo', { id: 'VIDEOID0001' });
  assert.equal(details.playerClient, 'TV');
  const idx = (itag) => details.formats.find((f) => f.itag === itag).index;
  const resolved = await bundle.call('resolveFormats', { id: 'VIDEOID0001', indices: [idx(401), idx(251)], itags: [401, 251] });
  const video = new URL(resolved.urls[String(idx(401))]);
  const audio = new URL(resolved.urls[String(idx(251))]);
  assert.equal(video.searchParams.get('fakeclient'), 'VISIONOS');
  assert.equal(audio.searchParams.get('fakeclient'), 'VISIONOS');
  assert.equal(video.searchParams.get('itag'), '401');
  assert.match(resolved.userAgent, /Safari/);
  assert.ok(bundle.logs.some((l) => l.level === 'info' && /googlevideo refused the TV stream \(itag 401, HTTP 403\)/.test(l.message)), 'a handled refusal is logged below the error level');
  const probes = yt.hits.filter((h) => h.path === '/videoplayback');
  assert.equal(probes.length, 2, 'one one-byte probe per stream source');
  assert.equal(probes[0].headers.range, 'bytes=0-0');
  const visionPlayer = yt.hits.find((h) => h.path === '/youtubei/v1/player' && h.body.context.client.clientName === 'VISIONOS');
  assert.ok(visionPlayer, 'visionOS was asked');
  assert.equal(visionPlayer.headers.cookie, undefined, 'the signed-out request carries no account cookies');
  assert.equal(visionPlayer.headers.authorization, undefined);
  // History still goes through the signed-in TV answer.
  const watched = await bundle.call('markWatched', { id: 'VIDEOID0001' });
  assert.equal(watched.ok, true);
  const playback = yt.hits.find((h) => h.path === '/api/stats/playback');
  assert.equal(new URL(playback.url).searchParams.get('c'), 'tvhtml5');
  assert.ok(playback.headers.cookie, 'history ping carries the account cookies');
});

test('when signed-out clients are refused too, the next signed-in client provides the streams', async () => {
  const yt = createFakeYouTube({ refuseStreams: ['TVHTML5', 'VISIONOS', 'TVHTML5_SIMPLY', 'iOS', 'ANDROID_VR'] });
  const bundle = loadBundle({ router: yt.router });
  await bundle.call('init', { cookie: COOKIE, client: 'AUTO' });
  const details = await bundle.call('videoInfo', { id: 'VIDEOID0001' });
  const idx = (itag) => details.formats.find((f) => f.itag === itag).index;
  const resolved = await bundle.call('resolveFormats', { id: 'VIDEOID0001', indices: [idx(401), idx(251)], itags: [401, 251] });
  // TV (403) → four signed-out clients (403) → TV as a Samsung set (TVHTML5, 403) → Web embedded.
  assert.equal(new URL(resolved.urls[String(idx(401))]).searchParams.get('fakeclient'), 'WEB_EMBEDDED_PLAYER');
  const again = await bundle.call('videoInfo', { id: 'VIDEOID0001' });
  assert.equal(again.playerClient, 'WEB_EMBEDDED');
});

test('an older init that finishes last does not replace the newer session', async () => {
  const yt = createFakeYouTube();
  const bundle = loadBundle({ router: yt.router });
  const first = bundle.call('init', { cookie: COOKIE, client: 'AUTO' });
  const second = bundle.call('init', { cookie: '', client: 'AUTO' });
  const results = await Promise.allSettled([first, second]);
  assert.equal(results[1].status, 'fulfilled');
  assert.equal(results[1].value.loggedIn, false);
  const state = await bundle.call('sessionState');
  assert.equal(state.loggedIn, false, 'the signed-out (newer) session stays installed');
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
  await assert.rejects(call('videoInfo', { id: 'DELETED0002', client: 'TV' }), (e) =>
    e.kind === 'unavailable' && e.message === 'This video isn’t available anymore');
  assert.equal(yt.hits.filter((h) => h.path === '/youtubei/v1/player').length, 2);
});

test('live streams come back as segmented formats without trying other clients', async () => {
  const { call, yt } = await connected();
  const players = () => yt.hits.filter((h) => h.path === '/youtubei/v1/player');
  const live = await call('videoInfo', { id: 'LIVESTREAM1', client: 'AUTO' });
  assert.equal(live.isLive, true);
  assert.ok(live.formats.length > 0 && live.formats.every((f) => f.isOtf), 'live segments are not streamable');
  const hlsOnly = await call('videoInfo', { id: 'LIVEHLSONLY', client: 'AUTO' });
  assert.deepEqual(hlsOnly.formats, []);
  assert.equal(players().length, 2);
  // Neither marked the TV client as broken: the next video is still loaded through it first.
  const next = await call('videoInfo', { id: 'VIDEOID0001', client: 'AUTO' });
  assert.equal(next.playerClient, 'TV');
  assert.equal(players().length, 3);
  assert.equal(next.formats.some((f) => f.isOtf), false);
});

test('changing the stream client setting starts the automatic choice over', async () => {
  const yt = createFakeYouTube({ tvReload: true });
  const bundle = loadBundle({ router: yt.router });
  await bundle.call('init', { cookie: COOKIE, client: 'AUTO' });
  assert.equal((await bundle.call('videoInfo', { id: 'VIDEOID0001' })).playerClient, 'TV_TIZEN');
  await bundle.call('setClient', { client: 'WEB_EMBEDDED' });
  assert.equal((await bundle.call('videoInfo', { id: 'VIDEOID0002', client: 'WEB_EMBEDDED' })).playerClient, 'WEB_EMBEDDED');
  await bundle.call('setClient', { client: 'AUTO' });
  const players = () => yt.hits.filter((h) => h.path === '/youtubei/v1/player')
    .map((h) => (h.body.context.client.deviceMake === 'Samsung' ? 'TV_TIZEN' : h.body.context.client.clientName));
  const before = players().length;
  assert.equal((await bundle.call('videoInfo', { id: 'VIDEOID0003', client: 'AUTO' })).playerClient, 'TV_TIZEN');
  // The manual choice (Web embedded) is not kept as the automatic first choice.
  assert.deepEqual(players().slice(before), ['TVHTML5', 'TV_TIZEN']);
});

test('Automatic skips Mobile web when PO tokens are off; picked by hand it is still tried', async () => {
  const yt = createFakeYouTube({ rejectClients: ['TVHTML5', 'WEB_EMBEDDED_PLAYER'] });
  const bundle = loadBundle({ router: yt.router });
  await bundle.call('init', { cookie: COOKIE, client: 'AUTO', poTokenMode: 'off' });
  await assert.rejects(bundle.call('videoInfo', { id: 'VIDEOID0001' }), (e) =>
    e.kind === 'extraction' && /MWEB: \[poToken\] .*PO tokens are turned off/.test(e.detail));
  const mweb = () => yt.hits.filter((h) => h.path === '/youtubei/v1/player' && h.body.context.client.clientName === 'MWEB');
  assert.equal(mweb().length, 0);
  await bundle.call('setClient', { client: 'MWEB' });
  const details = await bundle.call('videoInfo', { id: 'VIDEOID0001', client: 'MWEB' });
  assert.equal(details.playerClient, 'MWEB');
  assert.equal(mweb().length, 1);
});

test('stream links close to their expiry are not handed to the player', async () => {
  const yt = createFakeYouTube({ expiresInSeconds: '900' });
  const bundle = loadBundle({ router: yt.router });
  await bundle.call('init', { cookie: COOKIE, client: 'TV' });
  const details = await bundle.call('videoInfo', { id: 'VIDEOID0001', client: 'TV' });
  const audio = details.formats.find((f) => f.itag === 251);
  await assert.rejects(bundle.call('resolveFormats', { id: 'VIDEOID0001', indices: [audio.index], itags: [251] }), (e) => e.kind === 'expired');
  assert.equal((await bundle.call('sessionState')).cachedInfos, 0, 'the stale player data is dropped');
});

test('format indices from an earlier load of the video are refused as expired', async () => {
  const yt = createFakeYouTube({ reorderClients: ['WEB_EMBEDDED_PLAYER'] });
  const bundle = loadBundle({ router: yt.router });
  await bundle.call('init', { cookie: COOKIE, client: 'AUTO' });
  const tv = await bundle.call('videoInfo', { id: 'VIDEOID0001', client: 'AUTO' });
  await bundle.call('setClient', { client: 'WEB_EMBEDDED' });
  const embedded = await bundle.call('videoInfo', { id: 'VIDEOID0001', client: 'WEB_EMBEDDED' });
  const uhd = (d) => d.formats.find((f) => f.itag === 401);
  assert.notEqual(uhd(tv).index, uhd(embedded).index);
  // Back on Automatic, Swift still holds the TV details (cached for 5 minutes).
  await bundle.call('setClient', { client: 'AUTO' });
  await assert.rejects(bundle.call('resolveFormats', { id: 'VIDEOID0001', indices: [uhd(tv).index], itags: [401] }), (e) => e.kind === 'expired');
  const resolved = await bundle.call('resolveFormats', { id: 'VIDEOID0001', indices: [uhd(embedded).index], itags: [401] });
  assert.equal(new URL(resolved.urls[String(uhd(embedded).index)]).searchParams.get('itag'), '401');
  await assert.rejects(bundle.call('resolveFormats', { id: 'VIDEOID0001', indices: [99] }), (e) => e.kind === 'expired');
});

test('a player script without the n/sig function is reported as not ready', async () => {
  const yt = createFakeYouTube({ brokenPlayer: true });
  const bundle = loadBundle({ router: yt.router });
  const session = await bundle.call('init', { cookie: COOKIE, client: 'TV' });
  assert.equal(session.hasDecipher, false);
  assert.ok(bundle.logs.some((l) => /player script could not be analysed/.test(l.message)));
  assert.equal((await bundle.call('sessionState')).hasDecipher, false);
});
