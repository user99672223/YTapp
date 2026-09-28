// Watch page: video info, stream formats (deciphered on demand), captions, chapters, up next,
// watch-history + watch-time pings.
import { YT } from 'youtubei.js/web';
import { state, requireSession, putInfo, getInfo, clientMeta, likeStatusFor } from './state.js';
import { toItem } from './normalize.js';
import { text, bestThumb, videoThumb, fixUrl, clean } from './util.js';
import { fail, classify, BridgeError } from './errors.js';
import { contentPoToken } from './potoken.js';
import { tvIdentity } from './platform.js';

const HDR_TRANSFER = /2084|B67|HLG|PQ/i;

function codecsOf(mime) {
  const m = /codecs="([^"]+)"/.exec(mime || '');
  return m ? m[1] : '';
}

export function formatsOf(info) {
  const sd = info.streaming_data;
  if (!sd || !Array.isArray(sd.adaptive_formats)) return [];
  return sd.adaptive_formats.map((f, index) => {
    const transfer = f.color_info?.transfer_characteristics || '';
    return clean({
      index,
      itag: f.itag,
      mimeType: f.mime_type,
      codecs: codecsOf(f.mime_type),
      hasVideo: !!f.has_video,
      hasAudio: !!f.has_audio,
      width: f.width,
      height: f.height,
      fps: f.fps,
      bitrate: f.bitrate,
      averageBitrate: f.average_bitrate,
      contentLength: f.content_length,
      qualityLabel: f.quality_label,
      audioQuality: f.audio_quality,
      audioSampleRate: f.audio_sample_rate,
      audioChannels: f.audio_channels,
      loudnessDb: f.loudness_db,
      isDrc: !!f.is_drc,
      isHdr: HDR_TRANSFER.test(transfer) || /HDR/i.test(f.quality_label || ''),
      isOtf: !!f.is_type_otf,
      isSuperResolution: !!f.is_sr,
      audioTrackId: f.audio_track?.id,
      audioTrackName: f.audio_track?.display_name,
      isDefaultAudio: f.audio_track ? !!f.audio_track.audio_is_default : undefined,
      isOriginal: f.is_original,
      isDubbed: f.is_dubbed,
      isAutoDubbed: f.is_auto_dubbed,
      isDescriptive: f.is_descriptive,
      isSecondary: f.is_secondary,
      language: f.language || undefined,
      hasUrl: !!(f.url || f.signature_cipher || f.cipher),
      isDrm: Array.isArray(f.drm_families) && f.drm_families.length > 0,
      approxDurationMs: f.approx_duration_ms
    });
  });
}

function vttUrl(baseUrl) {
  const url = new URL(fixUrl(baseUrl));
  url.searchParams.set('fmt', 'vtt');
  return url.toString();
}

export function captionsOf(info) {
  const tracks = info.captions?.caption_tracks || [];
  return tracks.map((t) => {
    try {
      return {
        languageCode: t.language_code,
        name: text(t.name) || t.language_code,
        url: vttUrl(t.base_url),
        isAuto: t.kind === 'asr',
        vssId: t.vss_id
      };
    } catch {
      return null;
    }
  }).filter(Boolean);
}

export function chaptersOf(info) {
  const markers = info.player_overlays?.decorated_player_bar?.player_bar?.markers_map || [];
  for (const marker of markers) {
    const chapters = marker?.value?.chapters;
    if (chapters && chapters.length) {
      return chapters.map((c) => ({
        title: text(c.title) || '',
        startSeconds: (Number(c.time_range_start_millis) || 0) / 1000,
        thumbnail: bestThumb(c.thumbnail, 320)
      }));
    }
  }
  const memo = info.page?.[1]?.contents_memo;
  const items = memo ? memo.get('MacroMarkersListItem') || [] : [];
  const out = [];
  for (const item of items) {
    const seconds = item.on_tap_endpoint?.payload?.startTimeSeconds;
    if (typeof seconds !== 'number') continue;
    if (out.some((c) => c.startSeconds === seconds)) continue;
    out.push({ title: text(item.title) || '', startSeconds: seconds, thumbnail: bestThumb(item.thumbnail, 320) });
  }
  return out.sort((a, b) => a.startSeconds - b.startSeconds);
}

function upNextOf(info) {
  const feed = info.watch_next_feed || [];
  const items = [];
  const seen = new Set();
  for (const node of feed) {
    const item = toItem(node);
    if (item && item.type === 'video' && !item.isShort && !item.isLive && !seen.has(item.id)) {
      seen.add(item.id);
      items.push(item);
    }
  }
  return items.slice(0, 30);
}

function subscribedFor(channelId, secondary) {
  const legacy = secondary?.subscribe_button;
  if (legacy && typeof legacy.subscribed === 'boolean') return legacy.subscribed;
  const owner = secondary?.owner?.subscription_button;
  if (owner && typeof owner.subscribed === 'boolean') return owner.subscribed;
  const captured = state.subscriptions.get(channelId);
  return typeof captured === 'boolean' ? captured : undefined;
}

function playabilityOf(info) {
  const p = info.playability_status || {};
  return { status: p.status || 'UNKNOWN', reason: text(p.reason) || text(p.error_screen?.reason) || undefined };
}

export function checkPlayable(info) {
  const { status, reason } = playabilityOf(info);
  if (status === 'OK') return;
  const message = reason || `YouTube says this video can't be played (${status}).`;
  if (/not a bot|confirm you/i.test(message)) fail('botCheck', message, status);
  if (status === 'LOGIN_REQUIRED') fail('loginRequired', message, status);
  if (status === 'LIVE_STREAM_OFFLINE') fail('upcoming', message, status);
  fail('unavailable', message, status);
}

function formatCount(n) {
  if (typeof n !== 'number' || !Number.isFinite(n)) return undefined;
  if (n >= 1e9) return `${(n / 1e9).toFixed(n >= 1e10 ? 0 : 1).replace(/\.0$/, '')}B`;
  if (n >= 1e6) return `${(n / 1e6).toFixed(n >= 1e7 ? 0 : 1).replace(/\.0$/, '')}M`;
  if (n >= 1e3) return `${(n / 1e3).toFixed(n >= 1e4 ? 0 : 1).replace(/\.0$/, '')}K`;
  return String(n);
}

export function detailsOf(info, client) {
  const basic = info.basic_info || {};
  const primary = info.primary_info;
  const secondary = info.secondary_info;
  const owner = secondary?.owner;
  const channelId = basic.channel_id || owner?.author?.id;
  const meta = clientMeta(client);
  const upNext = upNextOf(info);
  let likeStatus = basic.is_liked ? 'like' : basic.is_disliked ? 'dislike' : undefined;
  if (!likeStatus) likeStatus = likeStatusFor(basic.id) || 'none';
  const viewCount = typeof basic.view_count === 'number' ? basic.view_count : parseInt(basic.view_count, 10);
  return {
    id: basic.id,
    title: text(primary?.title) || basic.title || '',
    description: text(secondary?.description) || basic.short_description || '',
    channel: {
      id: channelId,
      name: text(owner?.author?.name) || basic.author || basic.channel?.name || '',
      avatar: bestThumb(owner?.author?.thumbnails, 176),
      subscriberCountText: text(owner?.subscriber_count),
      isSubscribed: subscribedFor(channelId, secondary)
    },
    viewCountText: text(primary?.view_count?.view_count) || text(primary?.view_count?.short_view_count) ||
      (Number.isFinite(viewCount) ? `${viewCount.toLocaleString('en-US')} views` : undefined),
    publishedText: text(primary?.relative_date) || text(primary?.published),
    likeCountText: formatCount(basic.like_count),
    likeStatus,
    isLive: !!basic.is_live,
    isUpcoming: !!basic.is_upcoming,
    isPostLiveDvr: !!basic.is_post_live_dvr,
    durationSeconds: basic.duration,
    thumbnail: bestThumb(basic.thumbnail) || videoThumb(basic.id),
    chapters: chaptersOf(info),
    captions: captionsOf(info),
    formats: formatsOf(info),
    upNext,
    autoplayNextId: info.autoplay_video_endpoint?.payload?.videoId || upNext[0]?.id,
    commentsCountText: text(info.comments_entry_point_header?.comment_count),
    playerClient: meta.key,
    userAgent: meta.userAgent,
    trackingAvailable: !!info.page?.[0]?.playback_tracking,
    playability: playabilityOf(info)
  };
}

// ---------------------------------------------------------------- stream clients

// Tried in this order when the preferred client fails. All of them accept the account cookies
// (September 2026): TV (sent as the older 5.x TV app, see platform.js; the 7.x version gets
// SABR-only answers when signed in), TV_TIZEN (the same client as a Samsung TV, for sessions
// that get "The page needs to be reloaded"), WEB_EMBEDDED (no PO token, embeddable videos only)
// and MWEB (needs a PO token). TV_SIMPLY, ANDROID_VR, IOS and VISIONOS answer signed-in
// requests with 400.
export const FALLBACK_CLIENTS = ['TV', 'TV_TIZEN', 'WEB_EMBEDDED', 'MWEB'];

// Reasons that mean the video itself can't be played, so other clients won't help.
const VIDEO_GONE = /private|removed|terminated|deleted|does not exist|copyright|account associated/i;
// Failures that are about the client, not the video: skip that client for the rest of the session.
const CLIENT_BROKEN = /page needs to be reloaded|no longer supported|SABR|could not be deciphered|no adaptive formats/i;

export function clientChain(preferred) {
  const p = String(preferred || state.options.client || 'AUTO').toUpperCase();
  const first = p === 'AUTO' ? (state.goodClient || FALLBACK_CLIENTS[0]) : p;
  const chain = [first, ...FALLBACK_CLIENTS.filter((c) => c !== first)];
  return [...chain.filter((c) => !state.badClients.has(c)), ...chain.filter((c) => state.badClients.has(c))];
}

// Why this player response can't be streamed directly, or null when it can.
async function streamProblem(yt, info, client) {
  const formats = info.streaming_data?.adaptive_formats || [];
  if (!formats.length) return `${client} returned no adaptive formats`;
  const video = formats.find((f) => f.has_video && (f.url || f.signature_cipher || f.cipher));
  if (!video) return `${client} only offers SABR streams`;
  let url;
  try {
    url = await video.decipher(yt.session.player);
  } catch (e) {
    return `${client} stream URLs could not be deciphered: ${e && e.message ? e.message : e}`;
  }
  if (!url || !/^https?:/.test(url)) return `${client} stream URLs could not be deciphered`;
  if (/[?&]sabr=1/.test(url)) return `${client} only offers SABR streams`;
  return null;
}

// Loads the player response through the first client that gives directly playable streams.
// `load(client, poToken)` performs the request (getInfo or getBasicInfo).
export async function playerWithFallback(yt, id, preferred, load) {
  const failures = [];
  for (const c of clientChain(preferred)) {
    try {
      const poToken = await contentPoToken(c, id);
      // TV_TIZEN is YouTube.js' TV client with another device identity (platform.js).
      const ytClient = c === 'TV_TIZEN' ? 'TV' : c;
      if (ytClient === 'TV') tvIdentity.current = c === 'TV_TIZEN' ? 'tizen' : 'cobalt';
      const info = await load(ytClient, poToken || undefined);
      checkPlayable(info);
      const problem = await streamProblem(yt, info, c);
      if (problem) fail('extraction', problem);
      state.goodClient = c;
      state.badClients.delete(c);
      if (failures.length) console.info(`video ${id}: streams from ${c} (after ${failures.map((f) => f.client).join(', ')} failed)`);
      return { info, client: c, poToken: poToken || undefined };
    } catch (e) {
      const cls = classify(e);
      failures.push({ client: c, ...cls });
      console.warn(`video ${id}: stream client ${c} failed: [${cls.kind}${cls.status ? ` ${cls.status}` : ''}] ${cls.message}`);
      if (cls.status === 400 || CLIENT_BROKEN.test(cls.message)) state.badClients.set(c, cls.message);
      if (['network', 'timeout', 'noSession', 'upcoming'].includes(cls.kind)) break;
      if (cls.kind === 'unavailable' && VIDEO_GONE.test(cls.message)) break;
    }
  }
  const summary = failures.map((f) => `${f.client}: [${f.kind}${f.status ? ` ${f.status}` : ''}] ${f.message}`).join('\n');
  const telling = failures.find((f) => !['extraction', 'unknown', 'parse', 'poToken'].includes(f.kind));
  if (telling) throw new BridgeError(telling.kind, telling.message, summary);
  throw new BridgeError('extraction', `No stream client could play this video (tried ${failures.map((f) => f.client).join(', ')}).`, summary);
}

export async function videoInfo({ id, client }) {
  const yt = await requireSession();
  if (!id) fail('invalid', 'Missing video id.');
  const { info, client: c, poToken } = await playerWithFallback(yt, id, client,
    (name, token) => yt.getInfo(id, { client: name, po_token: token }));
  putInfo(id, { info, client: c, poToken });
  return detailsOf(info, c);
}

// Deciphers the chosen formats (by index into streaming_data.adaptive_formats).
export async function resolveFormats({ id, indices }) {
  const yt = await requireSession();
  const entry = getInfo(id);
  const formats = entry.info.streaming_data?.adaptive_formats || [];
  const urls = {};
  for (const index of indices || []) {
    const format = formats[index];
    if (!format) fail('extraction', `Format ${index} is not available any more.`);
    let url = await format.decipher(yt.session.player);
    // Web clients need the (video-bound) PO token on googlevideo requests too.
    if (entry.poToken && url && /^https?:/.test(url)) {
      const u = new URL(url);
      u.searchParams.set('pot', entry.poToken);
      url = u.toString();
    }
    if (!url || typeof url !== 'string' || !/^https?:/.test(url)) fail('extraction', `Could not get a stream URL for format ${format.itag}.`);
    if (/[?&]sabr=1/.test(url)) fail('extraction', `Format ${format.itag} is only available through SABR streaming (client ${entry.client}).`);
    urls[String(index)] = url;
  }
  const meta = clientMeta(entry.client);
  return {
    urls,
    userAgent: meta.userAgent,
    headers: { Origin: 'https://www.youtube.com', Referer: 'https://www.youtube.com/' }
  };
}

// ---------------------------------------------------------------- history sync

const MediaInfoProto = Object.getPrototypeOf(YT.VideoInfo.prototype);

export async function markWatched({ id }) {
  const entry = getInfo(id);
  const meta = clientMeta(entry.client);
  const info = entry.info;
  if (!info.page?.[0]?.playback_tracking) fail('unavailable', 'YouTube did not provide playback tracking for this video.');
  let response;
  try {
    if (meta.key === 'WEB' || typeof MediaInfoProto?.addToWatchHistory !== 'function') {
      response = await info.addToWatchHistory();
    } else {
      // VideoInfo#addToWatchHistory() always reports the WEB client; report the client that
      // actually fetched the stream so the ping matches the playback URL it came with.
      response = await MediaInfoProto.addToWatchHistory.call(info, meta.name, meta.version);
    }
  } catch (e) {
    fail('history', `Could not add the video to your YouTube history: ${e && e.message ? e.message : e}`);
  }
  entry.watchStarted = Date.now();
  return { ok: !!response?.ok, status: response?.status || 0, cpn: info.cpn };
}

export async function watchtime({ id, segments, cmt, playing, final, len, lact, rt, volume, muted, fmt, afmt }) {
  const yt = await requireSession();
  const entry = getInfo(id);
  const tracking = entry.info.page?.[0]?.playback_tracking;
  const base = tracking?.videostats_watchtime_url;
  if (!base) fail('unavailable', 'YouTube did not provide a watch-time URL for this video.');
  const meta = clientMeta(entry.client);
  const segs = Array.isArray(segments) && segments.length ? segments : [[cmt || 0, cmt || 0]];
  const params = {
    cpn: entry.info.cpn,
    st: segs.map((s) => Number(s[0] || 0).toFixed(3)).join(','),
    et: segs.map((s) => Number(s[1] || 0).toFixed(3)).join(','),
    cmt: Number(cmt || 0).toFixed(3),
    state: playing ? 'playing' : 'paused',
    rt: Number(rt || 0).toFixed(3),
    rtn: Math.round(Number(rt || 0)).toString(),
    lact: String(Math.max(0, Math.round(Number(lact) || 0))),
    volume: String(Math.round(Number(volume ?? 100))),
    muted: muted ? '1' : '0',
    fs: '1'
  };
  if (len) params.len = Number(len).toFixed(3);
  if (fmt) params.fmt = String(fmt);
  if (afmt) params.afmt = String(afmt);
  if (final) params.final = '1';
  const url = base.replace('https://s.', 'https://www.');
  try {
    const response = await yt.actions.stats(url, { client_name: meta.name, client_version: meta.version }, params);
    return { ok: !!response.ok, status: response.status };
  } catch (e) {
    fail('history', `Watch-time ping failed: ${e && e.message ? e.message : e}`);
  }
}
