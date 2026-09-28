// Browse feeds with continuations: Home, Subscriptions, channels, search, playlists, history.
import { state, requireSession, requireLogin, newKey, putFeed, getFeed } from './state.js';
import { sectionsFromNodes, page, toItem } from './normalize.js';
import { text, bestThumb, isChannelId, nodeType } from './util.js';
import { fail } from './errors.js';

function pageNodes(feed) {
  if (!feed) return [];
  if (feed.contents && Array.isArray(feed.contents.contents)) return feed.contents.contents;
  const pc = feed.page_contents;
  if (pc && Array.isArray(pc.contents)) return pc.contents;
  if (pc && pc.content && Array.isArray(pc.content.contents)) return pc.content.contents;
  return [];
}

function hasMore(feed) {
  try {
    return !!feed.has_continuation;
  } catch {
    return false;
  }
}

function register(prefix, kind, feed, extra = {}) {
  const key = newKey(prefix);
  putFeed(key, { kind, feed, ...extra });
  return key;
}

function toPage(key, feed, sections) {
  return page(sections, hasMore(feed) ? key : undefined);
}

// ---------------------------------------------------------------- Home / Subscriptions

export async function home() {
  const yt = await requireSession();
  const feed = await yt.getHomeFeed();
  const key = register('home', 'home', feed);
  return toPage(key, feed, sectionsFromNodes(pageNodes(feed)));
}

export async function subscriptions() {
  const yt = await requireSession();
  requireLogin(yt);
  const feed = await yt.getSubscriptionsFeed();
  const key = register('subs', 'feed', feed);
  return toPage(key, feed, sectionsFromNodes(pageNodes(feed)));
}

export async function subscribedChannels() {
  const yt = await requireSession();
  requireLogin(yt);
  let feed;
  let sections = [];
  let feedError;
  try {
    feed = await yt.getChannelsFeed();
    sections = onlyChannels(sectionsFromNodes(pageNodes(feed)), feed);
  } catch (e) {
    feedError = e;
  }
  if (feed && sections.length) {
    const key = register('channels', 'feed', feed, { channelsOnly: true });
    return toPage(key, feed, sections);
  }
  // The "All subscriptions" page changes shape from time to time; the guide (side menu) always
  // lists the subscribed channels, so fall back to it.
  let channels = [];
  try {
    channels = await guideChannels(yt);
  } catch (e) {
    if (feedError) throw feedError;
    throw e;
  }
  if (!channels.length && feedError) throw feedError;
  return page(channels.length ? [{ id: 'guide-channels', style: 'grid', items: channels }] : [], undefined);
}

async function guideChannels(yt) {
  const guide = await yt.getGuide();
  const out = [];
  const seen = new Set();
  const visit = (entry) => {
    const type = nodeType(entry);
    if (type === 'GuideCollapsibleEntry') {
      for (const child of entry.expandable_items || []) visit(child);
      return;
    }
    if (type !== 'GuideEntry') return;
    const id = entry.endpoint?.payload?.browseId;
    if (!isChannelId(id) || seen.has(id)) return;
    seen.add(id);
    const avatar = bestThumb(entry.thumbnails, 240);
    out.push({
      type: 'channel',
      id,
      name: text(entry.title) || '',
      // Guide avatars are 88 px; ask the image server for a TV-sized one.
      avatar: avatar ? avatar.replace(/=s\d+-/, '=s240-') : undefined,
      isSubscribed: true
    });
  };
  for (const section of guide.contents || []) {
    if (nodeType(section) !== 'GuideSubscriptionsSection') continue;
    for (const entry of section.items || []) visit(entry);
  }
  return out;
}

function onlyChannels(sections, feed) {
  const channels = sections.flatMap((s) => s.items).filter((i) => i.type === 'channel');
  if (channels.length) return [{ id: sections[0]?.id || 'channels', style: 'grid', items: channels }];
  const fallback = (feed.channels || []).map(toItem).filter(Boolean);
  return fallback.length ? [{ id: 'channels', style: 'grid', items: fallback }] : [];
}

// ---------------------------------------------------------------- Search

export async function searchSuggestions({ query }) {
  const yt = await requireSession();
  const q = String(query || '').trim();
  if (!q) return [];
  const list = await yt.getSearchSuggestions(q);
  return Array.isArray(list) ? list.filter((s) => typeof s === 'string').slice(0, 12) : [];
}

const FILTER_VALUES = {
  upload_date: ['all', 'today', 'week', 'month', 'year'],
  type: ['all', 'video', 'shorts', 'channel', 'playlist', 'movie'],
  duration: ['all', 'over_twenty_mins', 'under_three_mins', 'three_to_twenty_mins'],
  prioritize: ['relevance', 'popularity']
};

export async function search({ query, filters = {} }) {
  const yt = await requireSession();
  const q = String(query || '').trim();
  if (!q) fail('invalid', 'Type something to search for.');
  const f = {};
  for (const [name, allowed] of Object.entries(FILTER_VALUES)) {
    const v = filters[name];
    if (v && allowed.includes(v) && v !== 'all') f[name] = v;
  }
  if (Array.isArray(filters.features) && filters.features.length) f.features = filters.features;
  const result = await yt.search(q, f);
  const key = register('search', 'search', result);
  return toPage(key, result, sectionsFromNodes(result.results || []));
}

// ---------------------------------------------------------------- Channel

function channelHeader(channel, id) {
  const h = channel.header;
  const meta = channel.metadata || {};
  const out = {
    id: meta.external_id || id,
    name: meta.title,
    avatar: bestThumb(meta.avatar || meta.thumbnail, 240),
    description: meta.description,
    banner: undefined,
    handle: undefined,
    subscriberCountText: undefined,
    videoCountText: undefined
  };
  const type = nodeType(h);
  if (type === 'PageHeader') {
    const v = h.content;
    out.name = out.name || text(v?.title?.text) || text(h.page_title);
    const image = v?.image;
    out.avatar = out.avatar || bestThumb(image?.avatar?.image || image?.image, 240);
    out.banner = bestThumb(v?.banner?.image, 2560);
    const parts = (v?.metadata?.metadata_rows || []).flatMap((row) => (row.metadata_parts || []).map((p) => text(p.text))).filter(Boolean);
    out.handle = parts.find((p) => p.startsWith('@'));
    out.subscriberCountText = parts.find((p) => /subscriber/i.test(p));
    out.videoCountText = parts.find((p) => /video/i.test(p));
    if (!out.description) out.description = text(v?.description?.description);
  } else if (type === 'C4TabbedHeader') {
    out.name = out.name || text(h.author?.name);
    out.avatar = out.avatar || bestThumb(h.author?.thumbnails, 240);
    out.banner = bestThumb(h.tv_banner || h.banner, 2560);
    out.handle = text(h.channel_handle);
    out.subscriberCountText = text(h.subscribers);
    out.videoCountText = text(h.videos_count);
  } else if (h) {
    out.name = out.name || text(h.author?.name) || text(h.title);
  }
  let subscribed = channel.subscribe_button?.subscribed;
  if (typeof subscribed !== 'boolean') subscribed = state.subscriptions.get(out.id);
  out.isSubscribed = typeof subscribed === 'boolean' ? subscribed : undefined;
  return out;
}

export async function channel({ id }) {
  const yt = await requireSession();
  if (!id) fail('invalid', 'Missing channel id.');
  const ch = await yt.getChannel(id);
  const header = channelHeader(ch, id);
  const key = register('channel', 'channelBase', ch, { channelId: header.id });
  const tabs = [];
  const safe = (fn) => {
    try {
      return fn();
    } catch {
      return false;
    }
  };
  if (safe(() => ch.has_videos)) tabs.push('videos');
  if (safe(() => ch.has_shorts)) tabs.push('shorts');
  if (safe(() => ch.has_live_streams)) tabs.push('live');
  if (safe(() => ch.has_playlists)) tabs.push('playlists');
  return { channel: header, tabs, key };
}

export async function channelTab({ key, id, tab }) {
  let base = key ? state.feeds.get(key) : null;
  if (!base || base.kind !== 'channelBase') {
    const yt = await requireSession();
    const ch = await yt.getChannel(id);
    base = { kind: 'channelBase', feed: ch };
  }
  const ch = base.feed;
  let tabFeed;
  switch (tab) {
    case 'videos': tabFeed = await ch.getVideos(); break;
    case 'shorts': tabFeed = await ch.getShorts(); break;
    case 'live': tabFeed = await ch.getLiveStreams(); break;
    case 'playlists': tabFeed = await ch.getPlaylists(); break;
    default: fail('invalid', `Unknown channel tab ${tab}`);
  }
  const tabKey = register('channelTab', 'channelTab', tabFeed);
  const nodes = tabFeed.current_tab?.content?.contents || pageNodes(tabFeed);
  let sections = sectionsFromNodes(nodes);
  if (tab === 'shorts') {
    sections = sections.map((s) => ({ ...s, items: s.items.map((i) => (i.type === 'video' ? { ...i, isShort: true } : i)) }));
  }
  return toPage(tabKey, tabFeed, mergeGrids(sections));
}

// ---------------------------------------------------------------- Library

export async function playlist({ id }) {
  const yt = await requireSession();
  if (!id) fail('invalid', 'Missing playlist id.');
  const pl = await yt.getPlaylist(id);
  const key = register('playlist', 'playlist', pl);
  const items = (pl.items || []).map(toItem).filter(Boolean);
  const info = pl.info || {};
  return {
    info: {
      id,
      title: text(info.title) || (id === 'WL' ? 'Watch later' : id === 'LL' ? 'Liked videos' : ''),
      channelName: text(info.author?.name),
      videoCountText: text(info.total_items),
      thumbnail: bestThumb(info.thumbnails),
      isEditable: !!info.is_editable
    },
    page: toPage(key, pl, items.length ? [{ id: `pl-${key}`, style: 'grid', items }] : [])
  };
}

export async function history() {
  const yt = await requireSession();
  requireLogin(yt);
  const h = await yt.getHistory();
  const key = register('history', 'history', h);
  return toPage(key, h, sectionsFromNodes(h.sections || pageNodes(h), { titledItemSections: true }));
}

export async function playlists() {
  const yt = await requireSession();
  requireLogin(yt);
  const feed = await yt.getPlaylists();
  const key = register('playlists', 'feed', feed);
  let sections = sectionsFromNodes(pageNodes(feed));
  const lists = sections.flatMap((s) => s.items).filter((i) => i.type === 'playlist');
  if (!lists.length) {
    const fallback = (feed.playlists || []).map(toItem).filter((i) => i && i.type === 'playlist');
    sections = fallback.length ? [{ id: `pls-${key}`, style: 'grid', items: fallback }] : [];
  } else {
    sections = [{ id: `pls-${key}`, style: 'grid', items: lists }];
  }
  return toPage(key, feed, sections);
}

// ---------------------------------------------------------------- Continuations

function mergeGrids(sections) {
  const out = [];
  for (const s of sections) {
    const last = out[out.length - 1];
    if (last && last.style === 'grid' && s.style === 'grid' && !s.title) last.items.push(...s.items);
    else out.push({ ...s, items: s.items.slice() });
  }
  return out;
}

export async function more({ key }) {
  const entry = getFeed(key);
  const current = entry.feed;
  if (!hasMore(current)) return page([], undefined);
  const next = await current.getContinuation();
  entry.feed = next;
  let sections;
  switch (entry.kind) {
    case 'search':
      sections = sectionsFromNodes(next.results || []);
      break;
    case 'playlist': {
      const items = (next.items || []).map(toItem).filter(Boolean);
      sections = items.length ? [{ id: `pl-${key}-${Date.now()}`, style: 'grid', items }] : [];
      break;
    }
    case 'history':
      sections = sectionsFromNodes(next.sections || pageNodes(next), { titledItemSections: true });
      break;
    case 'channelTab':
      sections = mergeGrids(sectionsFromNodes(next.contents?.contents || pageNodes(next)));
      break;
    default:
      sections = sectionsFromNodes(pageNodes(next));
      if (entry.channelsOnly) sections = onlyChannels(sections, next);
  }
  return page(sections, hasMore(next) ? key : undefined);
}

export function isValidChannelId(id) {
  return isChannelId(id);
}
