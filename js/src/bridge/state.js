// Shared bridge state: the Innertube session, cached feed objects (for continuations) and
// video infos (for deciphering, history pings and ratings).
import { Innertube, Constants } from 'youtubei.js/web';
import { NativeCache, loadPlatform, TIZEN_USER_AGENT } from './platform.js';
import { fail } from './errors.js';
import { text, bestThumb, entityKeyStrings, isChannelId, nodeType } from './util.js';
import { addJSONResponseHook } from '../polyfills/fetch.js';

// One fixed desktop identity for InnerTube requests (the stream client UA is chosen per client).
export const DEFAULT_USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';

export const state = {
  yt: null,
  creating: null,
  options: { client: 'AUTO', poTokenMode: 'auto' },
  // Stream client that last produced playable streams, and clients that failed for reasons that
  // are not specific to one video (rejected request, SABR-only, no longer supported).
  goodClient: null,
  badClients: new Map(),
  feeds: new Map(),
  infos: new Map(),
  subscriptions: new Map(),
  likes: new Map(),
  keySeq: 0,
  lastAccount: null
};

const MAX_FEEDS = 40;
const MAX_INFOS = 12;

export function newKey(prefix) {
  state.keySeq += 1;
  return `${prefix}:${state.keySeq}`;
}

export function putFeed(key, entry) {
  state.feeds.delete(key);
  state.feeds.set(key, entry);
  while (state.feeds.size > MAX_FEEDS) state.feeds.delete(state.feeds.keys().next().value);
}

export function getFeed(key) {
  const entry = state.feeds.get(key);
  if (!entry) fail('expired', 'This list expired. Pull to refresh.', key);
  return entry;
}

export function putInfo(id, entry) {
  state.infos.delete(id);
  state.infos.set(id, { ...entry, at: Date.now() });
  while (state.infos.size > MAX_INFOS) state.infos.delete(state.infos.keys().next().value);
}

export function getInfo(id) {
  const entry = state.infos.get(id);
  if (!entry) fail('expired', 'Video information expired. Open the video again.', id);
  return entry;
}

// InnerTube client name/version and the user agent a stream client uses for googlevideo requests.
export function clientMeta(client) {
  const key = String(client || 'TV').toUpperCase();
  const alias = { YTKIDS: 'WEB_KIDS', TV_TIZEN: 'TV' }[key] || key;
  const c = Constants.CLIENTS[alias] || Constants.CLIENTS.WEB;
  return {
    key,
    name: c.NAME,
    version: c.VERSION,
    userAgent: key === 'TV_TIZEN' ? TIZEN_USER_AGENT : (c.USER_AGENT || DEFAULT_USER_AGENT)
  };
}

// Captures subscription / like states from frameworkUpdates in every InnerTube JSON response.
addJSONResponseHook((url, json) => {
  const mutations = json && json.frameworkUpdates && json.frameworkUpdates.entityBatchUpdate &&
    json.frameworkUpdates.entityBatchUpdate.mutations;
  if (!Array.isArray(mutations)) return;
  for (const mutation of mutations) {
    const payload = mutation && mutation.payload;
    if (!payload) continue;
    if (payload.subscriptionStateEntity) {
      const strings = entityKeyStrings(payload.subscriptionStateEntity.key || mutation.entityKey);
      const channelId = strings.find(isChannelId);
      if (channelId) state.subscriptions.set(channelId, !!payload.subscriptionStateEntity.subscribed);
    } else if (payload.likeStatusEntity) {
      const strings = entityKeyStrings(payload.likeStatusEntity.key || mutation.entityKey);
      const videoId = strings.find((s) => /^[\w-]{11}$/.test(s));
      if (videoId) state.likes.set(videoId, String(payload.likeStatusEntity.likeStatus || ''));
    }
  }
});

export function likeStatusFor(videoId) {
  const s = state.likes.get(videoId);
  if (s === 'LIKE') return 'like';
  if (s === 'DISLIKE') return 'dislike';
  if (s === 'INDIFFERENT') return 'none';
  return undefined;
}

let sharedCache = null;
function cache() {
  if (!sharedCache) sharedCache = new NativeCache(true, 'youtubei');
  return sharedCache;
}

export async function createInnertube(opts, retrievePlayer = true) {
  loadPlatform();
  return Innertube.create({
    cookie: opts.cookie || undefined,
    retrieve_player: retrievePlayer,
    cache: cache(),
    enable_session_cache: true,
    generate_session_locally: false,
    visitor_data: opts.visitorData || undefined,
    user_agent: opts.userAgent || DEFAULT_USER_AGENT,
    lang: opts.lang || undefined,
    location: opts.location || undefined,
    player_id: opts.playerId || undefined,
    po_token: opts.poToken || undefined,
    fail_fast: false
  });
}

export async function requireSession() {
  if (state.creating) await state.creating;
  if (!state.yt) fail('noSession', 'Not connected to YouTube yet.');
  return state.yt;
}

export function requireLogin(yt) {
  if (!yt.session.logged_in) fail('loginRequired', 'You need to be signed in (cookies) for this.');
}

export function parseAccount(info) {
  const contents = info?.contents?.contents || [];
  let item = contents.find((i) => nodeType(i) === 'AccountItem' && i.is_selected) ||
    contents.find((i) => nodeType(i) === 'AccountItem');
  if (!item) {
    const memo = info?.page?.contents_memo;
    const candidates = memo ? [...(memo.get('AccountItem') || []), ...(memo.get('ActiveAccountHeader') || [])] : [];
    item = candidates[0];
  }
  if (!item) fail('auth', 'YouTube did not return an account for these cookies.');
  const name = text(item.account_name);
  if (!name) fail('auth', 'YouTube did not return an account name for these cookies.');
  return {
    name,
    handle: text(item.channel_handle),
    photo: bestThumb(item.account_photo, 176),
    byline: text(item.account_byline)
  };
}
