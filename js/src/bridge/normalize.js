// Turns YouTube.js parser nodes into the plain JSON DTOs decoded by Swift
// (Packages/Core/Sources/Core/Models). Every accessor is defensive: YouTube changes its
// renderers often, so unknown shapes degrade to "skip this item" instead of throwing.
import {
  text, bestThumb, videoThumb, parseDuration, isDurationText, endpointBrowseId, endpointVideoId,
  isChannelId, nodeType, fixUrl
} from './util.js';

let sectionSeq = 0;
const nextSectionId = () => `s${++sectionSeq}`;

// ------------------------------------------------------------------ items

// English metadata wording: view counts, and the age or schedule of a video.
const VIEWS_RE = /\bviews?\b|watching|waiting/i;
const AGE_RE = /\bago\b|^streamed\b|^premiere|^scheduled\b/i;
// Lockup metadata texts that are stats, dates or labels, never a channel name.
const NOT_CHANNEL_RE = /^[\d.,]+\s*[KMB]?\s*(views?|watching|waiting|videos?|episodes?)\b|^no views$|\bago$|^(streamed|scheduled|premieres?|premiered|updated)\b|^view full playlist$|^(private|public|unlisted|playlist|mix|album|podcast)$/i;

// Picks the view count and the age out of a video's metadata texts. English wording is matched;
// in other UI languages the texts are taken in YouTube's "<views> • <age>" order.
function viewsAndAge(texts) {
  const viewCountText = texts.find((t) => VIEWS_RE.test(t));
  const publishedText = texts.find((t) => t !== viewCountText && AGE_RE.test(t));
  if (viewCountText || publishedText) return { viewCountText, publishedText };
  return { viewCountText: texts[0], publishedText: texts[1] };
}

function overlaysInfo(overlays) {
  const info = { durationText: undefined, isLive: false, isShort: false, isUpcoming: false, watchedPercent: undefined };
  const list = Array.isArray(overlays) ? overlays : [];
  const visitBadge = (badgeText, style) => {
    const t = (badgeText || '').trim();
    const s = (style || '').toUpperCase();
    if (isDurationText(t)) info.durationText = t;
    if (s.includes('LIVE') || t.toUpperCase() === 'LIVE') info.isLive = true;
    if (s.includes('SHORTS')) info.isShort = true;
    if (s.includes('UPCOMING')) info.isUpcoming = true;
  };
  for (const o of list) {
    const type = nodeType(o);
    if (type === 'ThumbnailOverlayTimeStatus') visitBadge(text(o.text), o.style);
    else if (type === 'ThumbnailOverlayResumePlayback') info.watchedPercent = Number(o.percent_duration_watched) || undefined;
    else if (type === 'ThumbnailOverlayBadgeView' || type === 'ThumbnailBottomOverlayView') {
      for (const b of o.badges || []) visitBadge(b.text, b.badge_style);
      const progress = o.progress_bar?.start_percent;
      if (progress != null) info.watchedPercent = Number(progress) || undefined;
    } else if (type === 'ThumbnailOverlayProgressBarView') {
      info.watchedPercent = Number(o.start_percent) || undefined;
    }
  }
  return info;
}

function authorInfo(author) {
  if (!author) return {};
  const id = isChannelId(author.id) ? author.id : endpointBrowseId(author.endpoint);
  return {
    channelName: text(author.name),
    channelId: isChannelId(id) ? id : undefined,
    channelAvatar: bestThumb(author.thumbnails, 176)
  };
}

function videoFromLegacy(node) {
  const id = node.video_id || node.id || endpointVideoId(node.endpoint);
  if (!id || typeof id !== 'string') return null;
  const overlay = overlaysInfo(node.thumbnail_overlays);
  const durationText = text(node.length_text) || text(node.duration?.text ? node.duration.text : node.duration) || overlay.durationText;
  const author = authorInfo(node.author);
  const badges = (node.badges || []).map((b) => (b.label || b.style || '').toUpperCase());
  const isLive = overlay.isLive || !!node.is_live || badges.some((b) => b.includes('LIVE'));
  const upcoming = !!node.upcoming || overlay.isUpcoming;
  let channelName = author.channelName;
  if (!channelName) channelName = text(node.short_byline_text) || text(node.long_byline_text);
  if (!channelName && typeof node.author === 'string') channelName = node.author;
  return {
    type: 'video',
    id,
    title: text(node.title) || '',
    channelName,
    channelId: author.channelId,
    channelAvatar: author.channelAvatar,
    thumbnail: bestThumb(node.thumbnails || node.thumbnail) || videoThumb(id),
    durationText,
    durationSeconds: node.duration?.seconds || parseDuration(durationText),
    viewCountText: text(node.short_view_count) || text(node.view_count) || text(node.views),
    publishedText: text(node.published),
    isLive,
    isShort: overlay.isShort,
    isUpcoming: upcoming,
    watchedPercent: overlay.watchedPercent,
    setVideoId: typeof node.set_video_id === 'string' ? node.set_video_id : undefined
  };
}

function lockupMetadataParts(lockup) {
  const rows = lockup.metadata?.metadata?.metadata_rows || [];
  return rows.map((row) => (row.metadata_parts || []).map((part) => ({
    text: text(part.text),
    endpoint: part.text?.endpoint || part.text?.runs?.find((r) => r && r.endpoint)?.endpoint
  })));
}

// Metadata rows are not positional: Home and Subscriptions put the author in the first row, but
// a channel's own tabs show a single "views • date" row and playlists show labels like "Private".
// The author is the part that links to a channel; without such a link the first row is taken
// only when more rows follow it and it does not read like a stat or a label.
function lockupChannel(lockup, parts) {
  const image = lockup.metadata?.image;
  let channelId = endpointBrowseId(image?.renderer_context?.command_context?.on_tap);
  let channelAvatar = bestThumb(image?.avatar?.image, 176);
  let channelName;
  for (const part of parts.flat()) {
    const id = endpointBrowseId(part.endpoint);
    if (!isChannelId(id)) continue;
    if (!isChannelId(channelId)) channelId = id;
    if (!channelName && part.text) channelName = part.text;
  }
  const first = parts[0]?.[0]?.text;
  if (!channelName && first && parts.length > 1 && !NOT_CHANNEL_RE.test(first)) channelName = first;
  return { channelName, channelId: isChannelId(channelId) ? channelId : undefined, channelAvatar };
}

function lockupImage(lockup) {
  const image = lockup.content_image;
  if (!image) return { thumbs: undefined, overlays: [] };
  if (nodeType(image) === 'CollectionThumbnailView') {
    return { thumbs: image.primary_thumbnail?.image, overlays: image.primary_thumbnail?.overlays || [] };
  }
  return { thumbs: image.image, overlays: image.overlays || [] };
}

function fromLockup(lockup) {
  const id = lockup.content_id;
  if (!id) return null;
  const parts = lockupMetadataParts(lockup);
  const title = text(lockup.metadata?.title) || '';
  const { thumbs, overlays } = lockupImage(lockup);
  const overlay = overlaysInfo(overlays);
  const type = lockup.content_type;
  if (type === 'CHANNEL') {
    return {
      type: 'channel', id, name: title,
      avatar: bestThumb(thumbs, 240) || lockupChannel(lockup, parts).channelAvatar,
      subscriberCountText: parts.flat().map((p) => p.text).find((t) => t && /subscriber/i.test(t))
    };
  }
  if (type === 'PLAYLIST' || type === 'ALBUM' || type === 'PODCAST' || type === 'SHOW') {
    const countBadge = overlays.flatMap((o) => o.badges || []).map((b) => b.text).find((t) => t && /\d/.test(t));
    return {
      type: 'playlist', id, title,
      thumbnail: bestThumb(thumbs),
      videoCountText: countBadge,
      channelName: lockupChannel(lockup, parts).channelName
    };
  }
  if (type !== 'VIDEO' && type !== 'SHORT' && type !== 'MOVIE' && type !== 'CLIP') return null;
  const channel = lockupChannel(lockup, parts);
  const flat = parts.flat().map((p) => p.text).filter(Boolean);
  const { viewCountText, publishedText } = viewsAndAge(flat.filter((t) => t !== channel.channelName));
  return {
    type: 'video',
    id,
    title,
    channelName: channel.channelName,
    channelId: channel.channelId,
    channelAvatar: channel.channelAvatar,
    thumbnail: bestThumb(thumbs) || videoThumb(id),
    durationText: overlay.durationText,
    durationSeconds: parseDuration(overlay.durationText),
    viewCountText,
    publishedText,
    isLive: overlay.isLive || flat.some((t) => /watching/i.test(t)),
    isShort: type === 'SHORT' || overlay.isShort,
    isUpcoming: overlay.isUpcoming,
    watchedPercent: overlay.watchedPercent
  };
}

function fromShortsLockup(node) {
  const id = endpointVideoId(node.on_tap_endpoint) || (typeof node.entity_id === 'string' ? node.entity_id.replace(/^shorts-shelf-item-/, '') : undefined);
  if (!id) return null;
  return {
    type: 'video',
    id,
    title: text(node.overlay_metadata?.primary_text) || text(node.accessibility_text) || '',
    thumbnail: bestThumb(node.thumbnail) || `https://i.ytimg.com/vi/${id}/oar2.jpg`,
    viewCountText: text(node.overlay_metadata?.secondary_text),
    isLive: false,
    isShort: true,
    isUpcoming: false
  };
}

function fromReelItem(node) {
  const id = node.id || endpointVideoId(node.endpoint);
  if (!id) return null;
  return {
    type: 'video', id, title: text(node.title) || '',
    thumbnail: bestThumb(node.thumbnails) || `https://i.ytimg.com/vi/${id}/oar2.jpg`,
    viewCountText: text(node.views),
    isLive: false, isShort: true, isUpcoming: false
  };
}

function fromChannel(node) {
  const id = node.id || node.author?.id || endpointBrowseId(node.endpoint);
  if (!id) return null;
  const subscribed = node.subscribe_button?.subscribed;
  // YouTube moved the @handle into subscriber_count and the subscriber count into video_count.
  let subscriberCountText = text(node.subscriber_count) || text(node.subscribers);
  let handle;
  if (subscriberCountText && subscriberCountText.startsWith('@')) {
    handle = subscriberCountText;
    subscriberCountText = text(node.video_count);
  }
  return {
    type: 'channel', id,
    name: text(node.author?.name) || text(node.title) || '',
    avatar: bestThumb(node.author?.thumbnails || node.thumbnails, 240),
    handle,
    subscriberCountText,
    isSubscribed: typeof subscribed === 'boolean' ? subscribed : undefined
  };
}

function fromPlaylist(node) {
  const id = node.id || node.endpoint?.payload?.playlistId;
  if (!id) return null;
  const thumbs = node.thumbnails?.length ? node.thumbnails : node.thumbnail_renderer?.thumbnail || node.thumbnail_renderer?.thumbnails;
  return {
    type: 'playlist', id,
    title: text(node.title) || '',
    thumbnail: bestThumb(thumbs),
    videoCountText: text(node.video_count_short) || text(node.video_count),
    channelName: text(node.author?.name) || text(node.author)
  };
}

export function toItem(node) {
  if (!node || typeof node !== 'object') return null;
  try {
    switch (nodeType(node)) {
      case 'RichItem':
        return toItem(node.content);
      case 'Video':
      case 'GridVideo':
      case 'CompactVideo':
      case 'PlaylistVideo':
      case 'PlaylistPanelVideo':
      case 'VideoCard':
      case 'GridMovie':
      case 'Movie':
        return videoFromLegacy(node);
      case 'LockupView':
        return fromLockup(node);
      case 'ShortsLockupView':
        return fromShortsLockup(node);
      case 'ReelItem':
        return fromReelItem(node);
      case 'Channel':
      case 'GridChannel':
        return fromChannel(node);
      case 'Playlist':
      case 'GridPlaylist':
      case 'CompactPlaylist':
      case 'CompactMix':
      case 'GridShow':
        return fromPlaylist(node);
      default:
        return null;
    }
  } catch (e) {
    console.warn('normalize: failed item', nodeType(node), e && e.message);
    return null;
  }
}

// ------------------------------------------------------------------ sections

const CONTAINER_KEYS = ['contents', 'items', 'content', 'cards'];

function shelfStyle(items) {
  return items.length > 0 && items.every((i) => i.type === 'video' && i.isShort) ? 'shorts' : 'row';
}

function collectItems(node, out, depth = 0) {
  if (!node || depth > 6) return;
  if (Array.isArray(node)) {
    for (const child of node) collectItems(child, out, depth + 1);
    return;
  }
  const item = toItem(node);
  if (item) {
    out.push(item);
    return;
  }
  // YouTube.js aliases some of these keys (e.g. ExpandedShelfContents/HorizontalList expose
  // `items` and a `contents` getter returning the same array); walk each child only once.
  const walked = [];
  for (const key of CONTAINER_KEYS) {
    const child = node[key];
    if (!child || typeof child !== 'object' || walked.includes(child)) continue;
    walked.push(child);
    collectItems(child, out, depth + 1);
  }
}

// Drops repeated items (same kind + id) within one section, keeping the first.
function uniqueItems(items) {
  const seen = new Set();
  return items.filter((i) => {
    const k = `${i.type}:${i.id}`;
    if (seen.has(k)) return false;
    seen.add(k);
    return true;
  });
}

function shelfSection(title, content, forceStyle) {
  const items = [];
  collectItems(content, items);
  if (!items.length) return null;
  return { id: nextSectionId(), title, style: forceStyle || shelfStyle(items), items };
}

// Walks a list of top-level page nodes and produces ordered sections: consecutive loose items
// become a 'grid' section; shelves become 'row' / 'shorts' sections.
export function sectionsFromNodes(nodes, options = {}) {
  const sections = [];
  let grid = null;
  const flushGrid = () => {
    if (grid && grid.items.length) sections.push(grid);
    grid = null;
  };
  const pushItem = (item) => {
    if (!grid) grid = { id: nextSectionId(), title: undefined, style: 'grid', items: [] };
    grid.items.push(item);
  };
  const visit = (node, depth) => {
    if (!node || depth > 8) return;
    if (Array.isArray(node)) {
      for (const child of node) visit(child, depth + 1);
      return;
    }
    const type = nodeType(node);
    switch (type) {
      case 'ContinuationItem':
      case 'ContinuationItemView':
      case 'FeedFilterChipBar':
      case 'ChipCloud':
      case 'HorizontalCardList':
      case 'SearchRefinementCard':
      case 'Message':
      case 'BackgroundPromo':
      case 'PromotedSparklesWeb':
      case 'AdSlot':
      case 'InFeedAdLayout':
      case 'StatementBanner':
      case 'BrandVideoShelf':
      case 'BrandVideoSingleton':
      case 'MerchandiseShelf':
      case 'TicketShelf':
      case 'EmergencyOnebox':
      case 'ClarificationRenderer':
      case 'PostRenderer':
      case 'BackstagePost':
      case 'Post':
      case 'SharedPost':
        return;
      case 'RichSection':
        visit(node.content, depth + 1);
        return;
      case 'RichShelf': {
        flushGrid();
        const s = shelfSection(text(node.title), node.contents);
        if (s) sections.push(s);
        return;
      }
      case 'ReelShelf': {
        flushGrid();
        const s = shelfSection(text(node.title) || 'Shorts', node.items, 'shorts');
        if (s) sections.push(s);
        return;
      }
      case 'GridShelfView': {
        flushGrid();
        const s = shelfSection(text(node.header?.title) || text(node.header?.text) || 'Shorts', node.contents);
        if (s) sections.push(s);
        return;
      }
      case 'Shelf': {
        flushGrid();
        const s = shelfSection(text(node.title), node.content);
        if (s) sections.push(s);
        return;
      }
      case 'ItemSection': {
        const title = text(node.header?.title);
        if (title && options.titledItemSections) {
          flushGrid();
          const items = [];
          const shelves = [];
          for (const child of node.contents || []) {
            const ct = nodeType(child);
            if (ct === 'ReelShelf' || ct === 'RichShelf' || ct === 'Shelf' || ct === 'GridShelfView') shelves.push(child);
            else collectItems(child, items);
          }
          if (items.length) sections.push({ id: nextSectionId(), title, style: 'grid', items });
          for (const shelf of shelves) visit(shelf, depth + 1);
          return;
        }
        visit(node.contents, depth + 1);
        return;
      }
      default: {
        const item = toItem(node);
        if (item) {
          if (options.skipShortsInGrid && item.type === 'video' && item.isShort) return;
          pushItem(item);
          return;
        }
        const walked = [];
        for (const key of CONTAINER_KEYS) {
          const child = node[key];
          if (!child || typeof child !== 'object' || walked.includes(child)) continue;
          walked.push(child);
          visit(child, depth + 1);
        }
      }
    }
  };
  visit(nodes, 0);
  flushGrid();
  return sections.map((s) => ({ ...s, items: uniqueItems(s.items) }));
}

export function page(sections, continuationKey) {
  return { sections, continuation: continuationKey || undefined };
}

// ------------------------------------------------------------------ comments

export function toComment(thread) {
  const c = thread?.comment || thread;
  if (!c || !c.comment_id) return null;
  return {
    id: c.comment_id,
    author: text(c.author?.name) || '',
    authorAvatar: fixUrl(c.author?.thumbnails?.[0]?.url) || fixUrl(c.author?.avatar_thumbnail_url),
    text: text(c.content) || '',
    publishedText: text(c.published_time),
    likeCountText: text(c.like_count),
    replyCountText: text(c.reply_count),
    isPinned: !!c.is_pinned,
    isCreator: !!c.author_is_channel_owner,
    isHearted: !!c.is_hearted
  };
}
