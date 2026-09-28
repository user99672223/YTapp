// PO (proof of origin) tokens via BgUtils + BotGuard, behind the DOM shim.
// Only web-type stream clients need them; the automatic (TV / Android VR / iOS) clients do not.
import { BotGuardClient } from 'bgutils-js/botguard';
import { WebPoMinter } from 'bgutils-js/webpo';
import { buildURL, GOOG_API_KEY, USER_AGENT } from 'bgutils-js/utils';
import { state } from './state.js';
import { installDomShim } from './domshim.js';
import { fail } from './errors.js';

const REQUEST_KEY = 'O43z0dpjhgX20SCx4KAo';
const NEEDS_PO_TOKEN = new Set(['WEB', 'MWEB', 'WEB_EMBEDDED', 'WEB_CREATOR', 'YTKIDS']);

const po = {
  minter: null,
  expiresAt: 0,
  creating: null,
  lastError: null,
  sessionToken: null
};

export function clientNeedsPoToken(client) {
  return NEEDS_PO_TOKEN.has(String(client || '').toUpperCase());
}

async function createMinter() {
  const yt = state.yt;
  if (!yt) fail('noSession', 'Not connected to YouTube yet.');
  installDomShim(USER_AGENT);
  const challenge = await yt.getAttestationChallenge('ENGAGEMENT_TYPE_UNBOUND');
  const bg = challenge?.bg_challenge;
  if (!bg) fail('poToken', 'YouTube did not send a BotGuard challenge.');
  const interpreterUrl = bg.interpreter_url?.private_do_not_access_or_else_trusted_resource_url_wrapped_value;
  if (!interpreterUrl) fail('poToken', 'BotGuard interpreter URL missing from the challenge.');
  const scriptResponse = await fetch(interpreterUrl.startsWith('//') ? `https:${interpreterUrl}` : interpreterUrl);
  if (!scriptResponse.ok) fail('poToken', `Could not download BotGuard (${scriptResponse.status}).`);
  const interpreter = await scriptResponse.text();
  // eslint-disable-next-line no-new-func
  new Function(interpreter)();
  const client = await BotGuardClient.create({ program: bg.program, globalName: bg.global_name, globalObject: globalThis });
  const webPoSignalOutput = [];
  const botguardResponse = await client.snapshot({ webPoSignalOutput }, 20000);
  const itResponse = await fetch(buildURL('GenerateIT', true), {
    method: 'POST',
    headers: {
      'content-type': 'application/json+protobuf',
      'x-goog-api-key': GOOG_API_KEY,
      'x-user-agent': 'grpc-web-javascript/0.1',
      'user-agent': USER_AGENT
    },
    body: JSON.stringify([REQUEST_KEY, botguardResponse])
  });
  if (!itResponse.ok) fail('poToken', `Integrity token request failed (${itResponse.status}).`);
  const itJson = await itResponse.json();
  const integrityToken = Array.isArray(itJson) ? itJson[0] : undefined;
  const ttl = Array.isArray(itJson) && typeof itJson[1] === 'number' ? itJson[1] : 3600;
  if (typeof integrityToken !== 'string') fail('poToken', 'YouTube did not issue an integrity token (the BotGuard check failed).');
  po.minter = await WebPoMinter.create({ integrityToken }, webPoSignalOutput);
  po.expiresAt = Date.now() + Math.max(300, ttl - 120) * 1000;
  // Session-bound token for streaming URLs (pot=) — bound to the visitor data.
  const visitorData = yt.session.context.client.visitorData;
  if (visitorData) {
    po.sessionToken = await po.minter.mintAsWebsafeString(visitorData);
    yt.session.po_token = po.sessionToken;
    if (yt.session.player) yt.session.player.po_token = po.sessionToken;
  }
  return po.minter;
}

async function minter() {
  if (po.minter && Date.now() < po.expiresAt) return po.minter;
  if (!po.creating) {
    po.creating = createMinter()
      .catch((e) => {
        po.lastError = e && e.message ? e.message : String(e);
        throw e;
      })
      .finally(() => {
        po.creating = null;
      });
  }
  return po.creating;
}

// Content-bound PO token for a player request, or null when the client does not need one.
export async function contentPoToken(client, videoId) {
  if (!clientNeedsPoToken(client) || state.options.poTokenMode === 'off') return null;
  try {
    const m = await minter();
    return await m.mintAsWebsafeString(videoId);
  } catch (e) {
    fail('poToken', `Could not create a PO token for the ${client} client: ${e && e.message ? e.message : e}. Set the stream client to Automatic in Settings.`);
  }
}

export function resetPoToken() {
  po.minter = null;
  po.expiresAt = 0;
  po.sessionToken = null;
}

export function poTokenState() {
  return {
    hasMinter: !!po.minter,
    expiresInSeconds: po.minter ? Math.max(0, Math.round((po.expiresAt - Date.now()) / 1000)) : 0,
    lastError: po.lastError || undefined
  };
}
