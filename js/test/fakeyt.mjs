// A tiny fake of the YouTube endpoints YouTube.js talks to, so the whole bridge (session creation,
// player-script analysis, deciphering, feeds, history pings, actions) runs offline in CI.
import { readFileSync } from 'node:fs';

export const PLAYER_ID = '0a1b2c3d';
export const CH1 = 'UC' + 'a'.repeat(22);
export const CH2 = 'UC' + 'b'.repeat(22);
export const COOKIE = 'SID=sid; HSID=hsid; SSID=ssid; APISID=apisid; SAPISID=sapisid123/abc; __Secure-3PAPISID=sapisid123/abc; LOGIN_INFO=li';

const playerJs = readFileSync(new URL('./fixtures/player.js', import.meta.url), 'utf8');

const runs = (t, browseId) => ({ runs: [{ text: t, ...(browseId ? { navigationEndpoint: { browseEndpoint: { browseId } } } : {}) }] });
const simple = (t) => ({ simpleText: t });
const thumbs = (url, w = 1280, h = 720) => ({ thumbnails: [{ url, width: w, height: h }] });

function swJsData() {
  const device = new Array(110).fill(null);
  device[0] = 'en';
  device[1] = 'US';
  device[3] = '203.0.113.7';
  device[11] = '';
  device[12] = '';
  device[13] = 'CgtWSVNJVE9SREFUQSiAgICAgA%3D%3D';
  device[16] = '2.20260623.01.00';
  device[17] = 'Macintosh';
  device[18] = '10_15_7';
  device[61] = ['x', 'APP_INSTALL_DATA'];
  device[79] = 'America/New_York';
  device[86] = 'Chrome';
  device[87] = '140.0.0.0';
  device[103] = '';
  device[107] = '';
  return `)]}'\n${JSON.stringify([[null, null, [[device], 'AIzaFakeKey']]])}`;
}

function videoRenderer(id, title, channelId, channelName, extra = {}) {
  return {
    videoRenderer: {
      videoId: id,
      thumbnail: thumbs(`https://i.ytimg.com/vi/${id}/hq720.jpg`),
      title: runs(title),
      longBylineText: runs(channelName, channelId),
      ownerText: runs(channelName, channelId),
      shortBylineText: runs(channelName, channelId),
      publishedTimeText: simple('3 days ago'),
      lengthText: simple('10:05'),
      viewCountText: simple('12,345 views'),
      shortViewCountText: simple('12K views'),
      navigationEndpoint: { watchEndpoint: { videoId: id } },
      channelThumbnailSupportedRenderers: {
        channelThumbnailWithLinkRenderer: {
          thumbnail: thumbs('https://yt3.ggpht.com/avatar-one', 68, 68),
          navigationEndpoint: { browseEndpoint: { browseId: channelId } }
        }
      },
      thumbnailOverlays: [
        { thumbnailOverlayTimeStatusRenderer: { text: simple('10:05'), style: 'DEFAULT' } },
        { thumbnailOverlayResumePlaybackRenderer: { percentDurationWatched: 40 } }
      ],
      ...extra
    }
  };
}

function lockup(id, title, channelId, channelName) {
  return {
    lockupViewModel: {
      contentImage: {
        thumbnailViewModel: {
          image: { sources: [{ url: `https://i.ytimg.com/vi/${id}/hq720.jpg`, width: 1280, height: 720 }] },
          overlays: [{
            thumbnailOverlayBadgeViewModel: {
              thumbnailBadges: [{ thumbnailBadgeViewModel: { text: '1:02:03', badgeStyle: 'THUMBNAIL_OVERLAY_BADGE_STYLE_DEFAULT' } }],
              position: 'THUMBNAIL_OVERLAY_BADGE_POSITION_BOTTOM_END'
            }
          }]
        }
      },
      metadata: {
        lockupMetadataViewModel: {
          title: { content: title },
          image: {
            decoratedAvatarViewModel: {
              avatar: { avatarViewModel: { image: { sources: [{ url: 'https://yt3.ggpht.com/avatar-two', width: 68, height: 68 }] } } },
              a11yLabel: `Go to channel ${channelName}`,
              rendererContext: { commandContext: { onTap: { innertubeCommand: { browseEndpoint: { browseId: channelId } } } } }
            }
          },
          metadata: {
            contentMetadataViewModel: {
              metadataRows: [
                { metadataParts: [{ text: { content: channelName } }] },
                { metadataParts: [{ text: { content: '1.2M views' } }, { text: { content: '2 weeks ago' } }] }
              ],
              delimiter: ' • '
            }
          }
        }
      },
      contentId: id,
      contentType: 'LOCKUP_CONTENT_TYPE_VIDEO',
      rendererContext: {}
    }
  };
}

function shortLockup(id, title) {
  return {
    shortsLockupViewModel: {
      entityId: `shorts-shelf-item-${id}`,
      accessibilityText: `${title}, 1.2 million views - play Short`,
      thumbnail: { sources: [{ url: `https://i.ytimg.com/vi/${id}/oar2.jpg`, width: 405, height: 720 }] },
      onTap: { innertubeCommand: { reelWatchEndpoint: { videoId: id } } },
      menuOnTap: { innertubeCommand: {} },
      indexInCollection: 0,
      menuOnTapA11yLabel: 'More actions',
      overlayMetadata: { primaryText: { content: title }, secondaryText: { content: '1.2M views' } }
    }
  };
}

function homeBrowse() {
  return {
    responseContext: {},
    contents: {
      twoColumnBrowseResultsRenderer: {
        tabs: [{
          tabRenderer: {
            selected: true,
            content: {
              richGridRenderer: {
                contents: [
                  { richItemRenderer: { content: videoRenderer('VIDEOID0001', 'First video', CH1, 'Channel One') } },
                  { richItemRenderer: { content: lockup('LOCKUPVID01', 'Lockup video', CH2, 'Channel Two') } },
                  {
                    richSectionRenderer: {
                      content: {
                        richShelfRenderer: {
                          title: runs('Shorts'),
                          contents: [
                            { richItemRenderer: { content: shortLockup('SHORTID0001', 'Short one') } },
                            { richItemRenderer: { content: shortLockup('SHORTID0002', 'Short two') } }
                          ]
                        }
                      }
                    }
                  },
                  { richItemRenderer: { content: videoRenderer('VIDEOID0002', 'Second video', CH1, 'Channel One') } },
                  {
                    continuationItemRenderer: {
                      trigger: 'CONTINUATION_TRIGGER_ON_ITEM_SHOWN',
                      continuationEndpoint: { continuationCommand: { token: 'HOMECONT1', request: 'CONTINUATION_REQUEST_TYPE_BROWSE' } }
                    }
                  }
                ]
              }
            }
          }
        }]
      }
    }
  };
}

function homeContinuation() {
  return {
    responseContext: {},
    onResponseReceivedActions: [{
      appendContinuationItemsAction: {
        targetId: 'browse-feedFEwhat_to_watch',
        continuationItems: [
          { richItemRenderer: { content: videoRenderer('VIDEOID0003', 'Third video', CH2, 'Channel Two') } }
        ]
      }
    }]
  };
}

const FORMAT_URL = (itag) => `https://rr1---sn-fake.googlevideo.com/videoplayback?expire=1999999999&ei=EI&ip=203.0.113.7&id=o-FAKE&itag=${itag}&source=youtube&mime=video%2Fwebm&n=abcdef&c=TVHTML5&sparams=expire%2Cei%2Cip%2Cid%2Citag%2Csource%2Cmime%2Cn%2Cc`;

function cipher(itag) {
  return `s=SIGXYZ&sp=sig&url=${encodeURIComponent(FORMAT_URL(itag))}`;
}

// Player answers for special video ids: an age gate, a bot check and a deleted video.
const NOT_PLAYABLE = {
  AGEGATED001: { status: 'LOGIN_REQUIRED', reason: 'Sign in to confirm your age. This video may be inappropriate for some users.' },
  BOTCHECK001: { status: 'LOGIN_REQUIRED', reason: 'Sign in to confirm you’re not a bot' },
  DELETED0001: {
    status: 'ERROR',
    reason: 'Video unavailable',
    errorScreen: { playerErrorMessageRenderer: { reason: simple('Video unavailable'), subreason: simple('This video has been removed by the uploader') } }
  }
};

function playerResponse(id) {
  return {
    responseContext: {},
    playabilityStatus: { status: 'OK', playableInEmbed: true },
    streamingData: {
      expiresInSeconds: '21540',
      adaptiveFormats: [
        { itag: 399, signatureCipher: cipher(399), mimeType: 'video/mp4; codecs="av01.0.08M.08"', bitrate: 2500000, width: 1920, height: 1080, fps: 30, qualityLabel: '1080p', quality: 'hd1080', contentLength: '100000000', approxDurationMs: '605000', averageBitrate: 2000000 },
        { itag: 401, signatureCipher: cipher(401), mimeType: 'video/mp4; codecs="av01.0.12M.08"', bitrate: 12000000, width: 3840, height: 2160, fps: 30, qualityLabel: '2160p', quality: 'hd2160', contentLength: '600000000', approxDurationMs: '605000' },
        { itag: 313, signatureCipher: cipher(313), mimeType: 'video/webm; codecs="vp9"', bitrate: 16000000, width: 3840, height: 2160, fps: 30, qualityLabel: '2160p', quality: 'hd2160', contentLength: '700000000', approxDurationMs: '605000' },
        { itag: 337, signatureCipher: cipher(337), mimeType: 'video/webm; codecs="vp09.02.51.10.01.09.16.09.00"', bitrate: 20000000, width: 3840, height: 2160, fps: 60, qualityLabel: '2160p60 HDR', quality: 'hd2160', colorInfo: { primaries: 'COLOR_PRIMARIES_BT2020', transferCharacteristics: 'COLOR_TRANSFER_CHARACTERISTICS_SMPTEST2084', matrixCoefficients: 'COLOR_MATRIX_COEFFICIENTS_BT2020_NCL' }, approxDurationMs: '605000' },
        { itag: 137, signatureCipher: cipher(137), mimeType: 'video/mp4; codecs="avc1.640028"', bitrate: 4000000, width: 1920, height: 1080, fps: 30, qualityLabel: '1080p', quality: 'hd1080', approxDurationMs: '605000' },
        { itag: 251, signatureCipher: cipher(251), mimeType: 'audio/webm; codecs="opus"', bitrate: 160000, averageBitrate: 130000, audioQuality: 'AUDIO_QUALITY_MEDIUM', audioSampleRate: '48000', audioChannels: 2, approxDurationMs: '605000', loudnessDb: -2.1 },
        { itag: 140, signatureCipher: cipher(140), mimeType: 'audio/mp4; codecs="mp4a.40.2"', bitrate: 130000, audioQuality: 'AUDIO_QUALITY_MEDIUM', audioSampleRate: '44100', audioChannels: 2, approxDurationMs: '605000' }
      ]
    },
    playbackTracking: {
      videostatsPlaybackUrl: { baseUrl: `https://s.youtube.com/api/stats/playback?cl=1&docid=${id}&ei=EI&ns=yt&plid=PLID&el=leanback&len=605&of=OF&vm=VM` },
      videostatsWatchtimeUrl: { baseUrl: `https://s.youtube.com/api/stats/watchtime?cl=1&docid=${id}&ei=EI&ns=yt&plid=PLID&el=leanback&len=605&of=OF&vm=VM` }
    },
    captions: {
      playerCaptionsTracklistRenderer: {
        captionTracks: [
          { baseUrl: `https://www.youtube.com/api/timedtext?v=${id}&lang=en&fmt=srv3`, name: simple('English'), vssId: '.en', languageCode: 'en', isTranslatable: true },
          { baseUrl: `https://www.youtube.com/api/timedtext?v=${id}&lang=de&kind=asr`, name: simple('German (auto-generated)'), vssId: 'a.de', languageCode: 'de', kind: 'asr', isTranslatable: true }
        ]
      }
    },
    videoDetails: {
      videoId: id, title: id === 'SHORTID0001' ? 'Short one' : 'First video', lengthSeconds: '605', channelId: CH1,
      isOwnerViewing: false, shortDescription: 'Description line\n0:00 Intro\n1:00 Part one', isCrawlable: true,
      thumbnail: thumbs(`https://i.ytimg.com/vi/${id}/maxresdefault.jpg`), allowRatings: true, viewCount: '12345',
      author: 'Channel One', isPrivate: false, isLiveContent: false
    }
  };
}

function nextResponse(id) {
  return {
    responseContext: {},
    contents: {
      twoColumnWatchNextResults: {
        results: {
          results: {
            contents: [
              {
                videoPrimaryInfoRenderer: {
                  title: runs('First video'),
                  viewCount: { videoViewCountRenderer: { viewCount: simple('12,345 views'), shortViewCount: simple('12K views') } },
                  dateText: simple('Jan 1, 2026'),
                  relativeDateText: simple('9 months ago'),
                  videoActions: { menuRenderer: { items: [], topLevelButtons: [] } }
                }
              },
              {
                videoSecondaryInfoRenderer: {
                  owner: {
                    videoOwnerRenderer: {
                      thumbnail: thumbs('https://yt3.ggpht.com/avatar-one', 88, 88),
                      title: runs('Channel One', CH1),
                      subscriberCountText: simple('1.5M subscribers'),
                      navigationEndpoint: { browseEndpoint: { browseId: CH1 } }
                    }
                  },
                  attributedDescription: { content: 'Description line\n0:00 Intro\n1:00 Part one' },
                  subscribeButton: {
                    subscribeButtonRenderer: {
                      buttonText: runs('Subscribed'), subscribed: true, enabled: true, type: 'FREE', channelId: CH1,
                      showPreferences: true
                    }
                  }
                }
              }
            ]
          }
        },
        secondaryResults: {
          secondaryResults: {
            results: [
              lockup('RELATEDVID1', 'Related one', CH2, 'Channel Two'),
              lockup('RELATEDVID2', 'Related two', CH2, 'Channel Two')
            ]
          }
        },
        autoplay: { autoplay: { sets: [] } }
      }
    },
    playerOverlays: {
      playerOverlayRenderer: {
        decoratedPlayerBarRenderer: {
          decoratedPlayerBarRenderer: {
            playerBar: {
              multiMarkersPlayerBarRenderer: {
                visibleOnLoad: { key: 'DESCRIPTION_CHAPTERS' },
                markersMap: [{
                  key: 'DESCRIPTION_CHAPTERS',
                  value: {
                    chapters: [
                      { chapterRenderer: { title: simple('Intro'), timeRangeStartMillis: 0, thumbnail: thumbs('https://i.ytimg.com/c0.jpg', 320, 180) } },
                      { chapterRenderer: { title: simple('Part one'), timeRangeStartMillis: 60000, thumbnail: thumbs('https://i.ytimg.com/c1.jpg', 320, 180) } }
                    ]
                  }
                }]
              }
            }
          }
        }
      }
    },
    frameworkUpdates: {
      entityBatchUpdate: {
        mutations: [{
          entityKey: 'EhhVQ2JiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYiAzKAE%3D',
          type: 'ENTITY_MUTATION_TYPE_REPLACE',
          payload: { subscriptionStateEntity: { key: `${Buffer.from([0x12, 24, ...Buffer.from(CH2)]).toString('base64')}`, subscribed: true } }
        }]
      }
    },
    currentVideoEndpoint: { watchEndpoint: { videoId: id } }
  };
}

function accountsList() {
  return {
    responseContext: {},
    contents: [{
      accountSectionListRenderer: {
        contents: [{
          accountItemSectionRenderer: {
            contents: [{
              accountItem: {
                accountName: simple('Test Household'),
                accountPhoto: thumbs('https://yt3.ggpht.com/me', 88, 88),
                isSelected: true,
                isDisabled: false,
                hasChannel: true,
                serviceEndpoint: {},
                accountByline: simple('test@example.com'),
                channelHandle: simple('@testhousehold')
              }
            }]
          }
        }]
      }
    }]
  };
}

function searchResponse() {
  return {
    responseContext: {},
    estimatedResults: '1000',
    contents: {
      twoColumnSearchResultsRenderer: {
        primaryContents: {
          sectionListRenderer: {
            contents: [{
              itemSectionRenderer: {
                contents: [
                  {
                    channelRenderer: {
                      channelId: CH2, title: simple('Channel Two'),
                      thumbnail: thumbs('//yt3.ggpht.com/two', 176, 176),
                      subscriberCountText: simple('@channeltwo'), videoCountText: simple('2.1M subscribers'),
                      navigationEndpoint: { browseEndpoint: { browseId: CH2 } },
                      subscribeButton: { subscribeButtonRenderer: { buttonText: runs('Subscribe'), subscribed: false, enabled: true, channelId: CH2 } }
                    }
                  },
                  videoRenderer('SEARCHVID01', 'Search hit', CH1, 'Channel One'),
                  {
                    reelShelfRenderer: {
                      title: runs('Shorts'),
                      items: [shortLockup('SHORTID0003', 'Search short')]
                    }
                  }
                ]
              }
            }]
          }
        }
      }
    }
  };
}

function channelsBrowse() {
  const channel = (id, name, subs) => ({
    channelRenderer: {
      channelId: id, title: simple(name),
      thumbnail: thumbs(`//yt3.ggpht.com/${id}=s176-c-k-c0x00ffffff-no-rj`, 176, 176),
      subscriberCountText: simple(subs),
      navigationEndpoint: { browseEndpoint: { browseId: id } },
      subscribeButton: { subscribeButtonRenderer: { buttonText: runs('Subscribed'), subscribed: true, enabled: true, channelId: id } }
    }
  });
  return {
    responseContext: {},
    contents: {
      twoColumnBrowseResultsRenderer: {
        tabs: [{
          tabRenderer: {
            selected: true,
            content: {
              sectionListRenderer: {
                contents: [{
                  itemSectionRenderer: {
                    contents: [{
                      shelfRenderer: {
                        content: {
                          expandedShelfContentsRenderer: {
                            items: [channel(CH1, 'Channel One', '1.1K subscribers'), channel(CH2, 'Channel Two', '2.1M subscribers')]
                          }
                        }
                      }
                    }]
                  }
                }]
              }
            }
          }
        }]
      }
    }
  };
}

function guideResponse() {
  const entry = (id, name) => ({
    guideEntryRenderer: {
      navigationEndpoint: { browseEndpoint: { browseId: id, canonicalBaseUrl: `/@${name.replace(/\s/g, '').toLowerCase()}` } },
      thumbnail: thumbs(`https://yt3.ggpht.com/${id}=s88-c-k-c0x00ffffff-no-rj`, 88, 88),
      formattedTitle: simple(name),
      entryData: { guideEntryData: { guideEntryId: id } }
    }
  });
  return {
    responseContext: {},
    items: [
      { guideSectionRenderer: { items: [{ guideEntryRenderer: { navigationEndpoint: { browseEndpoint: { browseId: 'FEwhat_to_watch' } }, formattedTitle: simple('Home') } }] } },
      {
        guideSubscriptionsSectionRenderer: {
          formattedTitle: simple('Subscriptions'),
          items: [
            entry(CH1, 'Channel One'),
            {
              guideCollapsibleEntryRenderer: {
                expanderItem: { guideEntryRenderer: { formattedTitle: simple('Show more') } },
                expandableItems: [entry(CH2, 'Channel Two'), entry(CH1, 'Channel One')],
                collapserItem: { guideEntryRenderer: { formattedTitle: simple('Show fewer') } }
              }
            },
            { guideEntryRenderer: { navigationEndpoint: { browseEndpoint: { browseId: 'FEchannels' } }, formattedTitle: simple('All subscriptions') } }
          ]
        }
      }
    ]
  };
}

function reelWatch(id) {
  return {
    responseContext: {},
    playerResponse: playerResponse(id),
    frameworkUpdates: {
      entityBatchUpdate: {
        mutations: [{
          entityKey: 'x',
          payload: { likeStatusEntity: { key: Buffer.from([0x0a, 11, ...Buffer.from(id)]).toString('base64'), likeStatus: 'LIKE' } }
        }]
      }
    }
  };
}

function reelSequence() {
  return {
    responseContext: {},
    entries: [
      { command: { reelWatchEndpoint: { videoId: 'SHORTID0002' } } },
      { command: { reelWatchEndpoint: { videoId: 'SHORTID0004' } } }
    ],
    continuationEndpoint: { continuationCommand: { token: 'REELCONT', request: 'CONTINUATION_REQUEST_TYPE_REEL_WATCH_SEQUENCE' } }
  };
}

export function createFakeYouTube(options = {}) {
  const hits = [];
  const router = (req) => {
    const url = new URL(req.url);
    const body = req.body ? JSON.parse(req.body) : null;
    hits.push({ path: url.pathname, url: req.url, headers: req.headers, body });
    const path = url.pathname;
    if (path === '/sw.js_data') return { status: 200, body: swJsData(), headers: { 'content-type': 'text/plain' } };
    if (path === '/youtubei/v1/config') return { status: 200, body: { configData: 'CFG', responseContext: {} } };
    if (path === '/iframe_api') return { status: 200, body: `var scriptUrl = 'https:\\/\\/www.youtube.com\\/s\\/player\\/${PLAYER_ID}\\/www-widgetapi.vflset\\/www-widgetapi.js';`, headers: { 'content-type': 'text/javascript' } };
    if (path === `/s/player/${PLAYER_ID}/player_es6.vflset/en_US/base.js`) return { status: 200, body: playerJs, headers: { 'content-type': 'text/javascript' } };
    if (path === '/youtubei/v1/account/accounts_list') {
      if (!req.headers.cookie) return { status: 401, body: { error: { code: 401 } } };
      return { status: 200, body: accountsList() };
    }
    if (path === '/youtubei/v1/browse') {
      if (body?.continuation === 'HOMECONT1') return { status: 200, body: homeContinuation() };
      if (body?.browseId === 'FEwhat_to_watch') return { status: 200, body: homeBrowse() };
      if (body?.browseId === 'FEchannels') {
        if (options.channelsFeed === 'broken') return { status: 200, body: { responseContext: {} } };
        return { status: 200, body: channelsBrowse() };
      }
      return { status: 404, body: { error: 'unknown browse' } };
    }
    if (path === '/youtubei/v1/guide') return { status: 200, body: guideResponse() };
    if (path === '/youtubei/v1/player') {
      const clientName = body?.context?.client?.clientName;
      // options.rejectClients: client names YouTube answers with 400 (as it did for TVHTML5 in 2026).
      // options.tvReload: TVHTML5 gets "The page needs to be reloaded" unless it says it is a Samsung TV.
      if (options.tvReload && clientName === 'TVHTML5' && body?.context?.client?.deviceMake !== 'Samsung') {
        return { status: 200, body: { responseContext: {}, playabilityStatus: { status: 'UNPLAYABLE', reason: 'The page needs to be reloaded.' } } };
      }
      if ((options.rejectClients || []).includes(clientName)) {
        return { status: 400, body: { error: { code: 400, message: 'Request contains an invalid argument.', status: 'INVALID_ARGUMENT' } } };
      }
      if (NOT_PLAYABLE[body.videoId]) return { status: 200, body: { responseContext: {}, playabilityStatus: NOT_PLAYABLE[body.videoId] } };
      return { status: 200, body: playerResponse(body.videoId) };
    }
    if (path === '/youtubei/v1/next') return { status: 200, body: nextResponse(body.videoId) };
    if (path === '/youtubei/v1/search') return { status: 200, body: searchResponse() };
    if (path === '/complete/search') return { status: 200, body: 'window.google.ac.h(["q",[["query one",0],["query two",0,[512]]],{"k":1}])', headers: { 'content-type': 'text/javascript' } };
    if (path === '/youtubei/v1/reel/reel_item_watch') return { status: 200, body: reelWatch(body.playerRequest?.videoId || body.videoId || 'SHORTID0001') };
    if (path === '/youtubei/v1/reel/reel_watch_sequence') return { status: 200, body: reelSequence() };
    if (path.startsWith('/api/stats/')) return { status: 204, body: '' };
    if (path === '/youtubei/v1/like/like' || path === '/youtubei/v1/like/dislike' || path === '/youtubei/v1/like/removelike') return { status: 200, body: { responseContext: {} } };
    if (path === '/youtubei/v1/subscription/subscribe' || path === '/youtubei/v1/subscription/unsubscribe') return { status: 200, body: { responseContext: {} } };
    if (path === '/youtubei/v1/browse/edit_playlist') return { status: 200, body: { responseContext: {}, status: 'STATUS_SUCCEEDED', actions: [] } };
    return { status: 404, body: { error: `unmocked ${path}` } };
  };
  return { router, hits };
}
