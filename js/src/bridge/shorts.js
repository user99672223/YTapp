// Shorts: seed from the Home feed's Shorts shelf, getShortsVideoInfo for each short, and the
// reel watch-sequence continuation for the endless feed.
import { state, requireSession, newKey, putFeed, getFeed, putInfo, clientMeta, likeStatusFor } from './state.js';
import { sectionsFromNodes } from './normalize.js';
import { text, bestThumb, endpointVideoId } from './util.js';
import { fail } from './errors.js';
import { formatsOf, captionsOf, playerWithFallback, formatCount } from './watch.js';
import { addJSONResponseHook } from '../polyfills/fetch.js';

// ---------------------------------------------------------------- reel overlay

// YouTube.js' ShortFormVideoInfo keeps only the player response of /reel/reel_item_watch, so the
// Short's overlay (like and comment counts, the channel's avatar) is read from the raw answer as
// it arrives, like the like/subscription states in state.js, and kept by video id.
const reelExtras = new Map();
const MAX_REEL_EXTRAS = 20;

// The first value under `key` in a depth-first walk of `node`.
function findKey(node, key, depth = 0) {
  if (!node || typeof node !== 'object' || depth > 16) return undefined;
  if (Array.isArray(node)) {
    for (const item of node) {
      const found = findKey(item, key, depth + 1);
      if (found !== undefined) return found;
    }
    return undefined;
  }
  if (Object.prototype.hasOwnProperty.call(node, key)) return node[key];
  for (const value of Object.values(node)) {
    const found = findKey(value, key, depth + 1);
    if (found !== undefined) return found;
  }
  return undefined;
}

// Like findKey, through view models wrapped in themselves ({ likeButtonViewModel: { likeButtonViewModel: … } }).
function findModel(node, key) {
  let found = findKey(node, key);
  while (found && typeof found === 'object' && found[key] && typeof found[key] === 'object') found = found[key];
  return found;
}

// A count as YouTube shows it ("1.2K", "12,345"), not a label ("Like", "Comments"). The reel answer
// is raw JSON, not YouTube.js nodes, so its texts can also be { simpleText }, which util's text()
// does not read.
function countText(value) {
  const s = text(value) ?? (typeof value?.simpleText === 'string' ? value.simpleText.trim() : undefined);
  return s && /^\d/.test(s) ? s : undefined;
}

// The exact number in an accessibility label ("like this video along with 12,345 other people"),
// not a compact one ("1.2K").
function labelNumber(label) {
  if (typeof label !== 'string') return undefined;
  const m = /(?:\d{1,3}(?:[,.\u00a0\u202f ]\d{3})+|\d+)(?![\d.,]*\s?[A-Za-z]{1,3}\b)/.exec(label);
  return m ? Number(m[0].replace(/\D/g, '')) : undefined;
}

function likeCountOf(overlay, liked) {
  const renderer = findKey(overlay, 'likeButtonRenderer');
  if (renderer && renderer.likesAllowed !== false) {
    const n = typeof renderer.likeCount === 'number' ? renderer.likeCount : parseInt(renderer.likeCount, 10);
    if (Number.isFinite(n)) return formatCount(n);
    // likeCountText is the count as it stands; likeCountWithLikeText is the count with the
    // viewer's like in it and likeCountWithUnlikeText the count without it.
    const shown = countText(renderer.likeCountText) ||
      countText(liked ? renderer.likeCountWithLikeText : renderer.likeCountWithUnlikeText);
    if (shown) return shown;
  }
  // The newer action bar: a toggle button whose title is the count (per state).
  const toggle = findModel(findModel(overlay, 'likeButtonViewModel'), 'toggleButtonViewModel');
  const button = findModel(liked ? toggle?.toggledButtonViewModel : toggle?.defaultButtonViewModel, 'buttonViewModel');
  const others = labelNumber(button?.accessibilityText);
  if (Number.isFinite(others) && !liked) return formatCount(others);
  return countText(button?.title);
}

function commentsCountOf(json, overlay) {
  for (const entry of json.engagementPanels || []) {
    const panel = entry?.engagementPanelSectionListRenderer;
    if (!panel || !/comment/i.test(`${panel.panelIdentifier || ''} ${panel.targetId || ''}`)) continue;
    const shown = countText(panel.header?.engagementPanelTitleHeaderRenderer?.contextualInfo);
    if (shown) return shown;
  }
  const legacy = findKey(overlay, 'viewCommentsButton')?.buttonRenderer;
  const legacyCount = countText(legacy?.text);
  if (legacyCount) return legacyCount;
  const buttons = findModel(overlay, 'reelActionBarViewModel')?.buttonViewModels || [];
  for (const b of buttons) {
    const vm = b && typeof b === 'object' && b.buttonViewModel ? findModel(b, 'buttonViewModel') : undefined;
    if (vm && /comment|message/i.test(`${vm.iconName || ''} ${vm.accessibilityText || ''}`)) {
      const shown = countText(vm.title);
      if (shown) return shown;
    }
  }
  return undefined;
}

function channelAvatarOf(overlay) {
  const header = findKey(overlay, 'reelPlayerHeaderRenderer');
  const legacy = bestThumb(header?.channelThumbnail, 176);
  if (legacy) return legacy;
  const bar = findModel(overlay, 'reelChannelBarViewModel');
  return bestThumb(findModel(bar, 'avatarViewModel')?.image?.sources, 176);
}

function reelVideoId(json) {
  return json.playerResponse?.videoDetails?.videoId || json.replacementEndpoint?.reelWatchEndpoint?.videoId ||
    findKey(json.overlay, 'likeButtonRenderer')?.target?.videoId;
}

function isLiked(id, overlay) {
  // state.js' hook, registered before this one, has read this answer's like state already.
  if (likeStatusFor(id)) return likeStatusFor(id) === 'like';
  const status = findKey(overlay, 'likeButtonRenderer')?.likeStatus || findModel(overlay, 'likeStatusEntity')?.likeStatus;
  return status === 'LIKE';
}

addJSONResponseHook((url, json) => {
  if (!url.includes('/reel/reel_item_watch') || !json || typeof json !== 'object') return;
  const id = reelVideoId(json);
  if (!id) return;
  const overlay = json.overlay;
  reelExtras.delete(id);
  reelExtras.set(id, {
    likeCountText: likeCountOf(overlay, isLiked(id, overlay)),
    commentsCountText: commentsCountOf(json, overlay),
    avatar: channelAvatarOf(overlay)
  });
  while (reelExtras.size > MAX_REEL_EXTRAS) reelExtras.delete(reelExtras.keys().next().value);
});

// Logged once: which of the overlay's details the reel answers don't have (YouTube changes them).
let reportedMissing = '';

function reportMissing(id, extras) {
  const missing = ['likeCountText', 'commentsCountText', 'avatar'].filter((k) => !extras[k]).join(', ');
  if (!missing || missing === reportedMissing) return;
  reportedMissing = missing;
  console.info(`short ${id}: the reel answer has no ${missing}; the Shorts buttons show their labels instead`);
}

// ---------------------------------------------------------------- feed

function sequenceIds(info) {
  const ids = [];
  for (const endpoint of info.watch_next_feed || []) {
    const id = endpointVideoId(endpoint);
    if (id && !ids.includes(id)) ids.push(id);
  }
  return ids;
}

async function seedFromHome(yt) {
  const feed = await yt.getHomeFeed();
  const nodes = feed.contents?.contents || [];
  const sections = sectionsFromNodes(nodes);
  for (const section of sections) {
    const short = section.items.find((i) => i.type === 'video' && i.isShort);
    if (short) return short.id;
  }
  fail('notFound', 'Your Home feed has no Shorts shelf right now, so there is nothing to start the Shorts feed from.');
}

export async function shortsFeed({ seedId } = {}) {
  const yt = await requireSession();
  const seed = seedId || await seedFromHome(yt);
  const info = await yt.getShortsVideoInfo(seed);
  const key = newKey('shorts');
  putFeed(key, { kind: 'shorts', feed: info });
  const ids = [seed, ...sequenceIds(info).filter((id) => id !== seed)];
  return { ids, continuation: info.wn_has_continuation ? key : undefined };
}

export async function shortsMore({ key }) {
  const entry = getFeed(key);
  if (!entry.feed.wn_has_continuation) return { ids: [], continuation: undefined };
  const info = await entry.feed.getWatchNextContinuation();
  entry.feed = info;
  return { ids: sequenceIds(info), continuation: info.wn_has_continuation ? key : undefined };
}

export async function shortInfo({ id, client }) {
  const yt = await requireSession();
  if (!id) fail('invalid', 'Missing short id.');
  // Metadata (and like/subscription entity states) through the Shorts API; streams through the
  // stream clients, like regular videos.
  const [reel, player] = await Promise.all([
    yt.getShortsVideoInfo(id).catch((e) => {
      console.warn('getShortsVideoInfo failed', e && e.message);
      return null;
    }),
    playerWithFallback(yt, id, client, (name, poToken) => yt.getBasicInfo(id, { client: name, po_token: poToken }))
  ]);
  const { info: playerInfo, client: c, poToken } = player;
  putInfo(id, { info: playerInfo, client: c, reel, poToken });
  const basic = (reel && reel.basic_info && reel.basic_info.title) ? reel.basic_info : playerInfo.basic_info;
  const channelId = basic.channel_id || playerInfo.basic_info.channel_id;
  const subscribed = state.subscriptions.get(channelId);
  const meta = clientMeta(c);
  const views = typeof basic.view_count === 'number' ? basic.view_count : parseInt(basic.view_count, 10);
  const extras = reelExtras.get(id) || {};
  if (reel) reportMissing(id, extras);
  return {
    id,
    title: text(basic.title) || '',
    channel: {
      id: channelId,
      name: text(basic.author) || '',
      avatar: extras.avatar,
      isSubscribed: typeof subscribed === 'boolean' ? subscribed : undefined
    },
    viewCountText: Number.isFinite(views) ? `${views.toLocaleString('en-US')} views` : undefined,
    likeCountText: extras.likeCountText,
    commentsCountText: extras.commentsCountText,
    likeStatus: likeStatusFor(id) || 'none',
    thumbnail: bestThumb(playerInfo.basic_info.thumbnail) || `https://i.ytimg.com/vi/${id}/oar2.jpg`,
    durationSeconds: playerInfo.basic_info.duration,
    formats: formatsOf(playerInfo),
    captions: captionsOf(playerInfo),
    playerClient: meta.key,
    userAgent: meta.userAgent,
    trackingAvailable: !!playerInfo.page?.[0]?.playback_tracking
  };
}
