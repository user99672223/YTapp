// Shorts: seed from the Home feed's Shorts shelf, getShortsVideoInfo for each short, and the
// reel watch-sequence continuation for the endless feed.
import { state, requireSession, newKey, putFeed, getFeed, putInfo, clientMeta, likeStatusFor } from './state.js';
import { sectionsFromNodes } from './normalize.js';
import { text, bestThumb, endpointVideoId } from './util.js';
import { fail } from './errors.js';
import { formatsOf, captionsOf, playerWithFallback } from './watch.js';

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
  return {
    id,
    title: text(basic.title) || '',
    channel: {
      id: channelId,
      name: text(basic.author) || '',
      isSubscribed: typeof subscribed === 'boolean' ? subscribed : undefined
    },
    viewCountText: Number.isFinite(views) ? `${views.toLocaleString('en-US')} views` : undefined,
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
