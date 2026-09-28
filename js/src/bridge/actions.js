// Account actions: rating, subscriptions, Watch Later, comments.
import { state, requireSession, requireLogin, newKey, putFeed, getFeed } from './state.js';
import { toComment } from './normalize.js';
import { text } from './util.js';
import { fail } from './errors.js';

function ensureOk(result, what) {
  if (result && result.success === false) fail('action', `${what} failed (HTTP ${result.status_code || '?'}).`);
  return result;
}

export async function rate({ id, rating }) {
  const yt = await requireSession();
  requireLogin(yt);
  if (!id) fail('invalid', 'Missing video id.');
  const info = state.infos.get(id)?.info;
  const viaInfo = info && typeof info.like === 'function' && info.primary_info;
  try {
    if (viaInfo) {
      if (rating === 'like') await info.like();
      else if (rating === 'dislike') await info.dislike();
      else await info.removeRating();
    } else {
      throw new Error('no watch-page buttons');
    }
  } catch (e) {
    // Fall back to the direct endpoints (Shorts, stale info, or "already liked" states).
    if (rating === 'like') ensureOk(await yt.interact.like(id), 'Like');
    else if (rating === 'dislike') ensureOk(await yt.interact.dislike(id), 'Dislike');
    else ensureOk(await yt.interact.removeRating(id), 'Remove rating');
  }
  state.likes.set(id, rating === 'like' ? 'LIKE' : rating === 'dislike' ? 'DISLIKE' : 'INDIFFERENT');
  return { likeStatus: rating === 'like' || rating === 'dislike' ? rating : 'none' };
}

export async function subscribe({ channelId, subscribe }) {
  const yt = await requireSession();
  requireLogin(yt);
  if (!channelId) fail('invalid', 'Missing channel id.');
  if (subscribe) ensureOk(await yt.interact.subscribe(channelId), 'Subscribe');
  else ensureOk(await yt.interact.unsubscribe(channelId), 'Unsubscribe');
  state.subscriptions.set(channelId, !!subscribe);
  return { isSubscribed: !!subscribe };
}

export async function watchLater({ id, add }) {
  const yt = await requireSession();
  requireLogin(yt);
  if (!id) fail('invalid', 'Missing video id.');
  if (add) await yt.playlist.addVideos('WL', [id]);
  else await yt.playlist.removeVideos('WL', [id]);
  return { inWatchLater: !!add };
}

// Asks YouTube which of the user's playlists already contain the video ("Save" dialog data).
export async function watchLaterStatus({ id }) {
  const yt = await requireSession();
  requireLogin(yt);
  const response = await yt.actions.execute('/playlist/get_add_to_playlist', { videoIds: [id], excludeWatchLater: false });
  const raw = response?.data;
  const found = [];
  const walk = (node, depth) => {
    if (!node || typeof node !== 'object' || depth > 12) return;
    if (Array.isArray(node)) {
      node.forEach((n) => walk(n, depth + 1));
      return;
    }
    const option = node.playlistAddToOptionRenderer;
    if (option && option.playlistId) {
      found.push({ id: option.playlistId, contains: option.containsSelectedVideos === 'ALL' });
      return;
    }
    for (const value of Object.values(node)) {
      if (value && typeof value === 'object') walk(value, depth + 1);
    }
  };
  walk(raw, 0);
  const wl = found.find((p) => p.id === 'WL');
  return { inWatchLater: wl ? wl.contains : undefined };
}

function commentsPage(key, comments) {
  const items = (comments.contents || []).map(toComment).filter(Boolean);
  return {
    countText: text(comments.header?.count) || text(comments.header?.comments_count),
    items,
    continuation: comments.has_continuation ? key : undefined
  };
}

export async function comments({ videoId, sort }) {
  const yt = await requireSession();
  if (!videoId) fail('invalid', 'Missing video id.');
  const result = await yt.getComments(videoId, sort === 'newest' ? 'NEWEST_FIRST' : 'TOP_COMMENTS');
  const key = newKey('comments');
  putFeed(key, { kind: 'comments', feed: result, videoId });
  return commentsPage(key, result);
}

export async function commentsMore({ key }) {
  const entry = getFeed(key);
  if (!entry.feed.has_continuation) return { items: [], continuation: undefined };
  const next = await entry.feed.getContinuation();
  entry.feed = next;
  return commentsPage(key, next);
}

export async function postComment({ videoId, text: body }) {
  const yt = await requireSession();
  requireLogin(yt);
  const message = String(body || '').trim();
  if (!videoId || !message) fail('invalid', 'Write something first.');
  const result = await yt.interact.comment(videoId, message);
  ensureOk(result, 'Posting the comment');
  return { posted: true };
}
