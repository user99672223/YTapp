// Session lifecycle: create / recreate the Innertube session, validate cookies, account info.
import { state, createInnertube, requireSession, requireLogin, parseAccount, DEFAULT_USER_AGENT } from './state.js';
import { resetPoToken, poTokenState } from './potoken.js';
import { fail } from './errors.js';

// YouTube.js keeps the analysed player script even when it could not find the n/sig decipher
// function in it (it only logs a warning), so `player.data` alone says nothing.
function decipherReady(player) {
  const exported = player?.data?.exported;
  return Array.isArray(exported) && exported.includes('nsigFunction');
}

function sessionSummary(yt, account, accountError) {
  const ctx = yt.session.context.client;
  return {
    loggedIn: !!yt.session.logged_in,
    account: account || undefined,
    accountError: accountError || undefined,
    visitorData: ctx.visitorData,
    clientName: state.options.client,
    playerId: yt.session.player?.player_id,
    signatureTimestamp: yt.session.player?.signature_timestamp,
    hasDecipher: decipherReady(yt.session.player),
    userAgent: yt.session.user_agent || DEFAULT_USER_AGENT
  };
}

export async function init(options = {}) {
  const opts = {
    cookie: typeof options.cookie === 'string' ? options.cookie.trim() : '',
    client: String(options.client || 'AUTO').toUpperCase(),
    visitorData: options.visitorData || '',
    userAgent: options.userAgent || DEFAULT_USER_AGENT,
    lang: options.lang || '',
    location: options.location || '',
    playerId: options.playerId || '',
    poTokenMode: options.poTokenMode === 'off' ? 'off' : 'auto'
  };
  const creating = (async () => {
    const yt = await createInnertube(opts, true);
    state.yt = yt;
    state.options = opts;
    state.feeds.clear();
    state.infos.clear();
    state.goodClient = null;
    state.badClients.clear();
    state.refusedClients.clear();
    resetPoToken();
    return yt;
  })();
  state.creating = creating.catch(() => null);
  let yt;
  try {
    yt = await creating;
  } finally {
    state.creating = null;
  }
  let account = null;
  let accountError = null;
  if (opts.cookie) {
    try {
      account = parseAccount(await yt.account.getInfo());
      state.lastAccount = account;
    } catch (e) {
      accountError = e && e.message ? e.message : String(e);
    }
  }
  if (!decipherReady(yt.session.player)) {
    console.warn('player script could not be analysed; deciphering will fail');
  }
  if (!(yt.session.player?.signature_timestamp > 0)) {
    console.warn('player script has no signature timestamp; YouTube may refuse player requests');
  }
  return sessionSummary(yt, account, accountError);
}

// Creates a throw-away session with the given cookies and asks YouTube who they belong to.
export async function validateCookie({ cookie }) {
  const value = String(cookie || '').trim();
  if (!value) fail('invalid', 'No cookies were provided.');
  if (!/SAPISID=|__Secure-3PAPISID=/.test(value)) {
    fail('auth', 'These cookies are missing SAPISID. Export them from youtube.com while signed in.');
  }
  const yt = await createInnertube({ cookie: value, userAgent: state.options.userAgent || DEFAULT_USER_AGENT, visitorData: state.options.visitorData }, false);
  let info;
  try {
    info = await yt.account.getInfo();
  } catch (e) {
    fail('auth', `YouTube rejected these cookies: ${e && e.message ? e.message : e}`);
  }
  return parseAccount(info);
}

export async function accountInfo() {
  const yt = await requireSession();
  requireLogin(yt);
  const account = parseAccount(await yt.account.getInfo());
  state.lastAccount = account;
  return account;
}

export async function sessionState() {
  const yt = state.yt;
  return {
    connected: !!yt,
    loggedIn: !!yt?.session.logged_in,
    clientName: state.options.client,
    playerId: yt?.session.player?.player_id,
    hasDecipher: decipherReady(yt?.session.player),
    visitorData: yt?.session.context.client.visitorData,
    cachedFeeds: state.feeds.size,
    cachedInfos: state.infos.size,
    poToken: poTokenState()
  };
}

export async function setClient({ client, poTokenMode }) {
  if (client) state.options.client = String(client).toUpperCase();
  if (poTokenMode) state.options.poTokenMode = poTokenMode === 'off' ? 'off' : 'auto';
  if (client || poTokenMode) {
    // A changed setting starts the automatic choice over: the client remembered as working may
    // have been the old manual choice, or one that only worked with the old PO-token mode.
    state.goodClient = null;
    state.badClients.clear();
  }
  return { clientName: state.options.client };
}
