// TubeBridge: the only API Swift calls. Swift invokes
//   TubeBridge.call(id, method, argsJSON)
// and receives the outcome through
//   __native.reply(id, errorJSON | null, resultJSON | null)
import { init, validateCookie, accountInfo, sessionState, setClient } from './session.js';
import {
  home, subscriptions, subscribedChannels, search, searchSuggestions, channel, channelTab, playlist,
  history, playlists, more
} from './feeds.js';
import { videoInfo, resolveFormats, markWatched, watchtime } from './watch.js';
import { shortsFeed, shortsMore, shortInfo } from './shorts.js';
import {
  rate, subscribe, watchLater, watchLaterStatus, comments, commentsMore, commentReplies, commentRepliesMore, postComment
} from './actions.js';
import { classify } from './errors.js';
import { clean } from './util.js';
import { nativeFn } from '../polyfills/native.js';
import { sha1Hex } from '../polyfills/base.js';

export const bundleInfo = {
  bundleVersion: __BUNDLE_VERSION__,
  youtubeiVersion: __YOUTUBEI_VERSION__,
  bgutilsVersion: __BGUTILS_VERSION__,
  protocol: 1
};

const methods = {
  init,
  validateCookie,
  accountInfo,
  sessionState,
  setClient,
  home,
  subscriptions,
  subscribedChannels,
  search,
  searchSuggestions,
  channel,
  channelTab,
  playlist,
  history,
  playlists,
  more,
  videoInfo,
  resolveFormats,
  markWatched,
  watchtime,
  shortsFeed,
  shortsMore,
  shortInfo,
  rate,
  subscribe,
  watchLater,
  watchLaterStatus,
  comments,
  commentsMore,
  commentReplies,
  commentRepliesMore,
  postComment,
  bundleInfo: async () => bundleInfo,
  ping: async () => ({ pong: true })
};

function reply(id, error, result) {
  const send = nativeFn('reply');
  if (!send) return;
  if (error) {
    send(id, JSON.stringify(clean(error)), null);
  } else {
    let json;
    try {
      json = JSON.stringify(clean(result === undefined ? null : result));
    } catch (e) {
      send(id, JSON.stringify(clean(classify(e))), null);
      return;
    }
    send(id, null, json);
  }
}

export const TubeBridge = {
  bundleInfo,
  methods: Object.keys(methods),
  // Synchronous helpers for tests and the debug screen.
  debug: { sha1Hex },
  call(id, method, argsJSON) {
    let args;
    try {
      args = argsJSON ? JSON.parse(argsJSON) : {};
    } catch (e) {
      reply(id, { kind: 'invalid', message: `Bad arguments for ${method}: ${e.message}` });
      return;
    }
    const fn = methods[method];
    if (!fn) {
      reply(id, { kind: 'invalid', message: `Unknown bridge method: ${method}` });
      return;
    }
    Promise.resolve()
      .then(() => fn(args || {}))
      .then((result) => reply(id, null, result), (error) => {
        const classified = classify(error);
        console.warn(`bridge ${method} failed: [${classified.kind}${classified.status ? ` ${classified.status}` : ''}] ${classified.message}${classified.detail ? ` | ${String(classified.detail).slice(0, 1500)}` : ''}`);
        reply(id, classified);
      });
  }
};
