// Account actions: rating, subscriptions, Watch Later, comments.
import { state, requireSession, requireLogin, newKey, putFeed, getFeed } from './state.js';
import { toComment, toCommentReplies } from './normalize.js';
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
  if (add) {
    await yt.playlist.addVideos('WL', [id]);
  } else {
    // One request by video id, like YouTube's own Save dialog. YouTube.js' removeVideos pages
    // through the whole list to find the entry, and fails when the video is not in it.
    const result = ensureOk(await yt.actions.execute('/browse/edit_playlist', {
      playlistId: 'WL',
      actions: [{ action: 'ACTION_REMOVE_VIDEO_BY_VIDEO_ID', removedVideoId: id }]
    }), 'Remove from Watch Later');
    // YouTube can answer 200 with a failed "status" in the body (it says "STATUS_SUCCEEDED" when done).
    const status = result?.data?.status;
    if (typeof status === 'string' && !/SUCCEEDED/.test(status)) fail('action', 'Remove from Watch Later failed.');
  }
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

// Threads loaded per comment section, for their replies. A section is one feed entry (so it counts
// once against the feed cache however many threads are opened); its reply lists live inside it.
const MAX_THREADS = 600;
const MAX_REPLY_LISTS = 30;

// "1,234" out of the header's "1,234 Comments" (its first run), else the short "1.2K" count.
function commentCountText(header) {
  const first = text(header?.count?.runs?.[0]?.text);
  if (first && /\d/.test(first)) return first;
  return text(header?.comments_count) || text(header?.count);
}

function commentsPage(key, entry, comments) {
  const items = [];
  for (const thread of comments.contents || []) {
    const item = toComment(thread);
    if (!item) continue;
    entry.threads.delete(item.id);
    entry.threads.set(item.id, thread);
    items.push(item);
  }
  while (entry.threads.size > MAX_THREADS) entry.threads.delete(entry.threads.keys().next().value);
  return {
    key,
    countText: commentCountText(comments.header),
    items,
    continuation: comments.has_continuation ? key : undefined
  };
}

function commentsEntry(key) {
  const entry = getFeed(key);
  if (entry.kind !== 'comments') fail('expired', 'These comments expired. Open them again.', key);
  return entry;
}

export async function comments({ videoId, sort }) {
  const yt = await requireSession();
  if (!videoId) fail('invalid', 'Missing video id.');
  let result;
  try {
    result = await yt.getComments(videoId, sort === 'newest' ? 'NEWEST_FIRST' : 'TOP_COMMENTS');
  } catch (e) {
    // YouTube answers without a comment section when comments are turned off.
    if (/did not have any content/i.test(String(e?.message || ''))) {
      fail('notFound', 'There are no comments to show. They may be turned off for this video.', e.message);
    }
    throw e;
  }
  const key = newKey('comments');
  const entry = { kind: 'comments', feed: result, videoId, threads: new Map(), replies: new Map() };
  putFeed(key, entry);
  return commentsPage(key, entry, result);
}

export async function commentsMore({ key }) {
  const entry = commentsEntry(key);
  if (!entry.feed.has_continuation) return { key, items: [], continuation: undefined };
  const next = await entry.feed.getContinuation();
  entry.feed = next;
  return commentsPage(key, entry, next);
}

// Replies continue from `<section key>#<comment id>`: the section entry holds where each opened
// thread stopped (the thread itself, then YouTube.js' CommentsContinuation for later batches).
const repliesKey = (key, commentId) => `${key}#${commentId}`;

function rememberReplies(entry, commentId, source, seen) {
  entry.replies.delete(commentId);
  entry.replies.set(commentId, { source, seen });
  while (entry.replies.size > MAX_REPLY_LISTS) entry.replies.delete(entry.replies.keys().next().value);
}

// The first batch of replies to a top-level comment of section `key`. Opening a thread again
// starts it over (YouTube.js reloads the first batch).
export async function commentReplies({ key, commentId }) {
  if (!commentId) fail('invalid', 'Missing comment id.');
  const entry = commentsEntry(key);
  const thread = entry.threads.get(commentId);
  if (!thread) fail('expired', 'This comment is no longer loaded. Open the comments again.', commentId);
  entry.replies.delete(commentId);
  if (!thread.has_replies) return toCommentReplies(commentId, [], undefined);
  await thread.getReplies();
  // No replies list in the answer: nothing to show and nothing to continue.
  const replies = thread.replies || [];
  const more = !!thread.replies && thread.has_continuation;
  const seen = new Set();
  if (more) rememberReplies(entry, commentId, thread, seen);
  return toCommentReplies(commentId, replies, more ? repliesKey(key, commentId) : undefined, seen);
}

export async function commentRepliesMore({ key }) {
  const at = String(key || '').lastIndexOf('#');
  if (at <= 0) fail('invalid', 'Bad replies key.', key);
  const commentId = key.slice(at + 1);
  const entry = commentsEntry(key.slice(0, at));
  const list = entry.replies.get(commentId);
  if (!list) fail('expired', 'These replies expired. Open the comment again.', key);
  const next = await list.source.getContinuation();
  const more = next.has_continuation;
  if (more) rememberReplies(entry, commentId, next, list.seen);
  else entry.replies.delete(commentId);
  return toCommentReplies(commentId, next.replies, more ? key : undefined, list.seen);
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
