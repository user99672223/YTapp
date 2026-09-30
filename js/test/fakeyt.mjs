// A tiny fake of the YouTube endpoints YouTube.js talks to, so the whole bridge (session creation,
// player-script analysis, deciphering, feeds, history pings, actions) runs offline in CI.
import { readFileSync } from 'node:fs';

export const PLAYER_ID = '0a1b2c3d';
export const CH1 = 'UC' + 'a'.repeat(22);
export const CH2 = 'UC' + 'b'.repeat(22);
export const CH3 = 'UC' + 'c'.repeat(22);
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

// A scheduled premiere as a search result: no length, the overlay only says "UPCOMING".
function upcomingVideoRenderer(id, title) {
  const r = videoRenderer(id, title, CH1, 'Channel One', {
    upcomingEventData: { startTime: '1999999999', upcomingEventText: runs('Premieres DATE_PLACEHOLDER') },
    thumbnailOverlays: [{ thumbnailOverlayTimeStatusRenderer: { text: runs('UPCOMING'), style: 'UPCOMING' } }]
  });
  delete r.videoRenderer.lengthText;
  delete r.videoRenderer.publishedTimeText;
  return r;
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

// A lockupViewModel with explicit metadata rows. A part is a string, or { text, browseId } for a
// part linking to a channel (an attributed-text command run, as YouTube sends the author).
function lockupView({ id, title, type = 'VIDEO', rows, badge = '12:34', badgeStyle = 'THUMBNAIL_OVERLAY_BADGE_STYLE_DEFAULT', thumb, onTap }) {
  const part = (p) => (typeof p === 'string'
    ? { text: { content: p } }
    : { text: { content: p.text, commandRuns: [{ startIndex: 0, length: p.text.length, onTap: { innertubeCommand: { browseEndpoint: { browseId: p.browseId } } } }] } });
  const image = {
    thumbnailViewModel: {
      image: { sources: [{ url: thumb || `https://i.ytimg.com/vi/${id}/hq720.jpg`, width: 1280, height: 720 }] },
      overlays: badge ? [{
        thumbnailOverlayBadgeViewModel: {
          thumbnailBadges: [{ thumbnailBadgeViewModel: { text: badge, badgeStyle } }],
          position: 'THUMBNAIL_OVERLAY_BADGE_POSITION_BOTTOM_END'
        }
      }] : []
    }
  };
  return {
    lockupViewModel: {
      contentImage: type === 'PLAYLIST' ? { collectionThumbnailViewModel: { primaryThumbnail: image } } : image,
      metadata: {
        lockupMetadataViewModel: {
          title: { content: title },
          metadata: { contentMetadataViewModel: { metadataRows: rows.map((r) => ({ metadataParts: r.map(part) })), delimiter: ' • ' } }
        }
      },
      contentId: id,
      contentType: `LOCKUP_CONTENT_TYPE_${type}`,
      rendererContext: onTap ? { commandContext: { onTap: { innertubeCommand: onTap } } } : {}
    }
  };
}

const richItem = (content) => ({ richItemRenderer: { content } });
const continuationItem = (token) => ({
  continuationItemRenderer: {
    trigger: 'CONTINUATION_TRIGGER_ON_ITEM_SHOWN',
    continuationEndpoint: { continuationCommand: { token, request: 'CONTINUATION_REQUEST_TYPE_BROWSE' } }
  }
});
const appendItems = (items) => ({
  responseContext: {},
  onResponseReceivedActions: [{ appendContinuationItemsAction: { targetId: 'browse-feed', continuationItems: items } }]
});
const browseTab = (content) => ({
  responseContext: {},
  contents: { twoColumnBrowseResultsRenderer: { tabs: [{ tabRenderer: { selected: true, content } }] } }
});

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

// `client` (the InnerTube client that asked) is kept on the URL so tests can refuse one client's streams.
const FORMAT_URL = (itag, client) => `https://rr1---sn-fake.googlevideo.com/videoplayback?expire=1999999999&ei=EI&ip=203.0.113.7&id=o-FAKE&itag=${itag}&source=youtube&mime=video%2Fwebm&n=abcdef&c=TVHTML5&sparams=expire%2Cei%2Cip%2Cid%2Citag%2Csource%2Cmime%2Cn%2Cc${client ? `&fakeclient=${client}` : ''}`;

function cipher(itag, client) {
  return `s=SIGXYZ&sp=sig&url=${encodeURIComponent(FORMAT_URL(itag, client))}`;
}

// Player answers for special video ids: an age gate, a bot check and a deleted video.
const NOT_PLAYABLE = {
  AGEGATED001: { status: 'LOGIN_REQUIRED', reason: 'Sign in to confirm your age. This video may be inappropriate for some users.' },
  BOTCHECK001: { status: 'LOGIN_REQUIRED', reason: 'Sign in to confirm you’re not a bot' },
  DELETED0001: {
    status: 'ERROR',
    reason: 'Video unavailable',
    errorScreen: { playerErrorMessageRenderer: { reason: simple('Video unavailable'), subreason: simple('This video has been removed by the uploader') } }
  },
  DELETED0002: { status: 'ERROR', reason: 'This video isn’t available anymore' }
};

// A live stream: segment formats (targetDurationSec / maxDvrDurationSec), or only an HLS manifest.
function livePlayerResponse(id) {
  const segment = (itag, extra) => ({ itag, url: FORMAT_URL(itag), targetDurationSec: 5, maxDvrDurationSec: 43200, approxDurationMs: '0', ...extra });
  return {
    responseContext: {},
    playabilityStatus: { status: 'OK', playableInEmbed: true },
    streamingData: {
      expiresInSeconds: '21540',
      hlsManifestUrl: 'https://manifest.googlevideo.com/api/manifest/hls_variant/fake',
      ...(id === 'LIVEHLSONLY' ? {} : {
        adaptiveFormats: [
          segment(137, { mimeType: 'video/mp4; codecs="avc1.640028"', bitrate: 4000000, width: 1920, height: 1080, fps: 30, qualityLabel: '1080p' }),
          segment(140, { mimeType: 'audio/mp4; codecs="mp4a.40.2"', bitrate: 130000, audioQuality: 'AUDIO_QUALITY_MEDIUM', audioSampleRate: '44100', audioChannels: 2 })
        ]
      })
    },
    videoDetails: {
      videoId: id, title: 'Live now', lengthSeconds: '0', channelId: CH1, isLive: true, isLiveContent: true,
      thumbnail: thumbs(`https://i.ytimg.com/vi/${id}/maxresdefault.jpg`), viewCount: '10', author: 'Channel One'
    }
  };
}

function playerResponse(id, options = {}) {
  if (id.startsWith('LIVE')) return livePlayerResponse(id);
  const formats = [
    { itag: 399, signatureCipher: cipher(399, options.client), mimeType: 'video/mp4; codecs="av01.0.08M.08"', bitrate: 2500000, width: 1920, height: 1080, fps: 30, qualityLabel: '1080p', quality: 'hd1080', contentLength: '100000000', approxDurationMs: '605000', averageBitrate: 2000000 },
    { itag: 401, signatureCipher: cipher(401, options.client), mimeType: 'video/mp4; codecs="av01.0.12M.08"', bitrate: 12000000, width: 3840, height: 2160, fps: 30, qualityLabel: '2160p', quality: 'hd2160', contentLength: '600000000', approxDurationMs: '605000' },
    { itag: 313, signatureCipher: cipher(313, options.client), mimeType: 'video/webm; codecs="vp9"', bitrate: 16000000, width: 3840, height: 2160, fps: 30, qualityLabel: '2160p', quality: 'hd2160', contentLength: '700000000', approxDurationMs: '605000' },
    { itag: 337, signatureCipher: cipher(337, options.client), mimeType: 'video/webm; codecs="vp09.02.51.10.01.09.16.09.00"', bitrate: 20000000, width: 3840, height: 2160, fps: 60, qualityLabel: '2160p60 HDR', quality: 'hd2160', colorInfo: { primaries: 'COLOR_PRIMARIES_BT2020', transferCharacteristics: 'COLOR_TRANSFER_CHARACTERISTICS_SMPTEST2084', matrixCoefficients: 'COLOR_MATRIX_COEFFICIENTS_BT2020_NCL' }, approxDurationMs: '605000' },
    { itag: 137, signatureCipher: cipher(137, options.client), mimeType: 'video/mp4; codecs="avc1.640028"', bitrate: 4000000, width: 1920, height: 1080, fps: 30, qualityLabel: '1080p', quality: 'hd1080', approxDurationMs: '605000' },
    { itag: 251, signatureCipher: cipher(251, options.client), mimeType: 'audio/webm; codecs="opus"', bitrate: 160000, averageBitrate: 130000, audioQuality: 'AUDIO_QUALITY_MEDIUM', audioSampleRate: '48000', audioChannels: 2, approxDurationMs: '605000', loudnessDb: -2.1 },
    { itag: 140, signatureCipher: cipher(140, options.client), mimeType: 'audio/mp4; codecs="mp4a.40.2"', bitrate: 130000, audioQuality: 'AUDIO_QUALITY_MEDIUM', audioSampleRate: '44100', audioChannels: 2, approxDurationMs: '605000' }
  ];
  return {
    responseContext: {},
    playabilityStatus: { status: 'OK', playableInEmbed: true },
    streamingData: {
      expiresInSeconds: options.expiresInSeconds || '21540',
      // options.reversed: this client lists the same formats in another order.
      adaptiveFormats: options.reversed ? formats.reverse() : formats
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
              // The Mix of this video: it starts with the video being watched.
              lockupView({
                id: `RD${id}`, type: 'PLAYLIST', title: 'Mix – First video', badge: 'Mix', rows: [['Channel One, Channel Two and more'], ['Updated today']],
                onTap: { watchEndpoint: { videoId: id, playlistId: `RD${id}`, params: 'OAHyAQIIAQ%3D%3D' } }
              }),
              lockup('RELATEDVID1', 'Related one', CH2, 'Channel Two'),
              // A promotion shaped like a video card that opens the Premium page.
              lockupView({
                id: 'PROMOPREM01', title: 'Try YouTube Premium', rows: [['YouTube']], badge: '',
                onTap: { browseEndpoint: { browseId: 'SPunlimited' } }
              }),
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
                  },
                  upcomingVideoRenderer('UPCOMINGV02', 'Scheduled premiere'),
                  lockupView({
                    id: 'RDMIXSEEDVID1', type: 'PLAYLIST', title: 'Mix – Channel One', badge: 'Mix',
                    thumb: 'https://i.ytimg.com/vi/MIXSEEDVID1/hqdefault.jpg',
                    rows: [['Channel One, Channel Two and more'], ['Updated today']],
                    onTap: { watchEndpoint: { videoId: 'MIXSEEDVID1', playlistId: 'RDMIXSEEDVID1', params: 'OAHyAQIIAQ%3D%3D' } }
                  }),
                  lockupView({
                    id: 'PLsearchlist01', type: 'PLAYLIST', title: 'Search playlist', badge: '12 videos',
                    thumb: 'https://i.ytimg.com/vi/VIDEOID0001/hqdefault.jpg',
                    rows: [[{ text: 'Channel Two', browseId: CH2 }, 'Playlist'], ['View full playlist']],
                    onTap: { watchEndpoint: { videoId: 'VIDEOID0001', playlistId: 'PLsearchlist01' } }
                  }),
                  {
                    gridShelfViewModel: {
                      header: { sectionHeaderViewModel: { headline: { content: 'Latest Shorts from Channel One' } } },
                      contents: [shortLockup('SHORTID0005', 'Grid short')]
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

const subscribedChannel = (id, name, subs) => ({
  channelRenderer: {
    channelId: id, title: simple(name),
    thumbnail: thumbs(`//yt3.ggpht.com/${id}=s176-c-k-c0x00ffffff-no-rj`, 176, 176),
    subscriberCountText: simple(subs),
    navigationEndpoint: { browseEndpoint: { browseId: id } },
    subscribeButton: { subscribeButtonRenderer: { buttonText: runs('Subscribed'), subscribed: true, enabled: true, channelId: id } }
  }
});

const channelShelf = (...channels) => ({
  itemSectionRenderer: {
    contents: [{ shelfRenderer: { content: { expandedShelfContentsRenderer: { items: channels } } } }]
  }
});

function channelsBrowse() {
  return browseTab({
    sectionListRenderer: {
      contents: [
        channelShelf(subscribedChannel(CH1, 'Channel One', '1.1K subscribers'), subscribedChannel(CH2, 'Channel Two', '2.1M subscribers')),
        continuationItem('CHANCONT1')
      ]
    }
  });
}

// Subscriptions: lockups only (2026), with an ended stream, a scheduled one and a live one.
function subscriptionsBrowse() {
  const by = (text, browseId) => ({ text, browseId });
  return browseTab({
    richGridRenderer: {
      contents: [
        richItem(lockupView({ id: 'SUBSVIDEO01', title: 'Subscribed video', rows: [[by('Channel Two', CH2)], ['5K views', '1 hour ago']] })),
        richItem(lockupView({
          id: 'STREAMVID01', title: 'Yesterday stream', badge: '2:01:15',
          thumb: 'https://i.ytimg.com/vi/STREAMVID01/hq720_live.jpg?sqp=-oaymwEcCNAFEJQDSFXyq4qpAw4IARUAAIhCGAFwAcABBg==&rs=AOn4CLfake',
          rows: [[by('Channel One', CH1)], ['20K views', 'Streamed 13 hours ago']]
        })),
        richItem(lockupView({
          id: 'UPCOMINGV01', title: 'Scheduled stream', badge: 'Upcoming',
          thumb: 'https://i.ytimg.com/vi/UPCOMINGV01/hqdefault_live.jpg',
          rows: [[by('Channel One', CH1)], ['Scheduled for 10/1/26, 8:00 PM']]
        })),
        richItem(lockupView({
          id: 'LIVENOWVID1', title: 'Live now', badge: 'LIVE', badgeStyle: 'THUMBNAIL_OVERLAY_BADGE_STYLE_LIVE',
          thumb: 'https://i.ytimg.com/vi/LIVENOWVID1/hq720_live.jpg',
          rows: [[by('Channel Two', CH2)], ['1.2K watching']]
        })),
        continuationItem('SUBSCONT1')
      ]
    }
  });
}

// Library → Playlists: playlist lockups whose first metadata part is not a channel.
function playlistsBrowse() {
  return browseTab({
    richGridRenderer: {
      contents: [
        richItem(lockupView({ id: 'PLmine000001', type: 'PLAYLIST', title: 'My list', badge: '3 videos', rows: [['Private', 'Playlist'], ['View full playlist']] })),
        richItem(lockupView({
          id: 'PLother00001', type: 'PLAYLIST', title: 'Saved list', badge: '40 videos',
          rows: [[{ text: 'Channel Two', browseId: CH2 }, 'Playlist'], ['View full playlist']]
        })),
        continuationItem('PLAGGCONT1')
      ]
    }
  });
}

// Watch later: playlistVideoRenderer rows carry views and age in one "videoInfo" line.
function watchLaterBrowse() {
  const row = (id, title, index) => ({
    playlistVideoRenderer: {
      videoId: id,
      thumbnail: thumbs(`https://i.ytimg.com/vi/${id}/hqdefault.jpg`, 480, 360),
      title: { runs: [{ text: title }], accessibility: { accessibilityData: { label: `${title} by Channel One 4 minutes` } } },
      index: simple(String(index)),
      shortBylineText: runs('Channel One', CH1),
      lengthText: simple('4:20'),
      lengthSeconds: '260',
      navigationEndpoint: { watchEndpoint: { videoId: id, playlistId: 'WL', index: index - 1 } },
      setVideoId: `SET${id}`,
      isPlayable: true,
      videoInfo: { runs: [{ text: '1.2M views' }, { text: ' • ' }, { text: '3 years ago' }] },
      thumbnailOverlays: [{ thumbnailOverlayTimeStatusRenderer: { text: simple('4:20'), style: 'DEFAULT' } }]
    }
  });
  return browseTab({
    sectionListRenderer: {
      contents: [{
        itemSectionRenderer: {
          contents: [{ playlistVideoListRenderer: { playlistId: 'WL', isEditable: true, canReorder: true, contents: [row('VIDEOID0001', 'First video', 1)] } }]
        }
      }]
    }
  });
}

// A channel page. Without params it is the Home tab; params 'VIDEOS' selects the Videos tab,
// whose lockups have a single "views • date" metadata row and no author.
function channelBrowse(id, params) {
  const name = id === CH1 ? 'Channel One' : 'Channel Two';
  const handle = id === CH1 ? '@videogamefan' : '@channeltwo';
  const prefix = id === CH1 ? 'ONE' : 'TWO';
  const tab = (title, path, tabParams, content) => ({
    tabRenderer: {
      title,
      selected: !!content,
      endpoint: {
        browseEndpoint: { browseId: id, params: tabParams, canonicalBaseUrl: `/${handle}` },
        commandMetadata: { webCommandMetadata: { url: `/${handle}/${path}`, webPageType: 'WEB_PAGE_TYPE_CHANNEL', apiUrl: '/youtubei/v1/browse' } }
      },
      ...(content ? { content } : {})
    }
  });
  const videos = params === 'VIDEOS' ? {
    richGridRenderer: {
      contents: [
        richItem(lockupView({ id: `${prefix}VIDEO01`, title: `${name} upload`, rows: [['1.2M views', '3 days ago']] })),
        richItem(lockupView({ id: `${prefix}VIDEO02`, title: `${name} older upload`, rows: [['900 views', '2 years ago']] }))
      ]
    }
  } : null;
  return {
    responseContext: {},
    header: {
      pageHeaderRenderer: {
        pageTitle: name,
        content: {
          pageHeaderViewModel: {
            title: { dynamicTextViewModel: { text: { content: name } } },
            metadata: {
              contentMetadataViewModel: {
                metadataRows: [
                  { metadataParts: [{ text: { content: handle } }] },
                  { metadataParts: [{ text: { content: '1.5M subscribers' } }, { text: { content: '321 videos' } }] }
                ],
                delimiter: ' • '
              }
            }
          }
        }
      }
    },
    metadata: { channelMetadataRenderer: { title: name, description: `About ${name}`, externalId: id, avatar: thumbs(`https://yt3.ggpht.com/${prefix}`, 176, 176) } },
    contents: {
      twoColumnBrowseResultsRenderer: {
        tabs: [
          tab('Home', 'featured', 'HOME', videos ? null : { sectionListRenderer: { contents: [] } }),
          tab('Videos', 'videos', 'VIDEOS', videos)
        ]
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

// The reel overlay in its two shapes: renderers (like count as a number, comment count in the
// comments engagement panel's header, avatar in the player header) and the newer view models
// (counts as button titles and accessibility labels, avatar in the metapanel's channel bar).
function reelOverlayRenderers(id) {
  return {
    overlay: {
      reelPlayerOverlayRenderer: {
        style: 'REEL_PLAYER_OVERLAY_STYLE_SHORTS',
        likeButton: {
          likeButtonRenderer: {
            target: { videoId: id }, likeStatus: 'LIKE', likesAllowed: true, likeCount: 12345,
            likeCountText: simple('12K'), likeCountWithLikeText: simple('12K'), likeCountWithUnlikeText: simple('12K')
          }
        },
        reelPlayerHeaderSupportedRenderers: {
          reelPlayerHeaderRenderer: {
            reelTitleText: runs('Short one'), timestampText: simple('2 days ago'),
            channelNavigationEndpoint: { browseEndpoint: { browseId: CH1 } },
            channelTitleText: runs('Channel One', CH1),
            channelThumbnail: {
              thumbnails: [
                { url: '//yt3.ggpht.com/short-avatar=s48', width: 48, height: 48 },
                { url: '//yt3.ggpht.com/short-avatar=s88', width: 88, height: 88 },
                { url: '//yt3.ggpht.com/short-avatar=s176', width: 176, height: 176 }
              ]
            }
          }
        },
        viewCommentsButton: {
          buttonRenderer: { text: simple('1,234'), icon: { iconType: 'COMMENT' }, accessibility: { label: 'View 1,234 comments' } }
        }
      }
    },
    engagementPanels: [
      { engagementPanelSectionListRenderer: { panelIdentifier: 'shorts-description-panel', header: { engagementPanelTitleHeaderRenderer: { title: runs('Description') } } } },
      {
        engagementPanelSectionListRenderer: {
          header: { engagementPanelTitleHeaderRenderer: { title: runs('Comments'), contextualInfo: runs('1.2K') } },
          content: { sectionListRenderer: { contents: [] } },
          targetId: 'engagement-panel-comments-section',
          visibility: 'ENGAGEMENT_PANEL_VISIBILITY_HIDDEN'
        }
      }
    ]
  };
}

// The renderers without the exact numbers: no numeric likeCount and no comments engagement panel,
// so the like count comes from the like button's texts and the comment count from the comments
// button, both { simpleText } like YouTube sends them.
function reelOverlayRenderersTextOnly(id) {
  const { overlay } = reelOverlayRenderers(id);
  const renderer = overlay.reelPlayerOverlayRenderer;
  return {
    overlay: {
      reelPlayerOverlayRenderer: {
        ...renderer,
        likeButton: {
          likeButtonRenderer: {
            target: { videoId: id }, likeStatus: 'INDIFFERENT', likesAllowed: true,
            likeCountWithLikeText: simple('988'), likeCountWithUnlikeText: simple('987')
          }
        }
      }
    },
    engagementPanels: [
      { engagementPanelSectionListRenderer: { panelIdentifier: 'shorts-description-panel', header: { engagementPanelTitleHeaderRenderer: { title: runs('Description') } } } }
    ]
  };
}

function reelOverlayViewModels() {
  const button = (iconName, title, accessibilityText) => ({ buttonViewModel: { iconName, title, accessibilityText } });
  return {
    overlay: {
      reelPlayerOverlayRenderer: {
        style: 'REEL_PLAYER_OVERLAY_STYLE_SHORTS',
        metapanel: {
          reelMetapanelViewModel: {
            metadataItems: [{
              reelChannelBarViewModel: {
                channelName: { content: '@channeltwo' },
                decoratedAvatarViewModel: {
                  avatar: {
                    avatarViewModel: {
                      image: {
                        sources: [
                          { url: 'https://yt3.ggpht.com/short-two=s88', width: 88, height: 88 },
                          { url: 'https://yt3.ggpht.com/short-two=s176', width: 176, height: 176 },
                          { url: 'https://yt3.ggpht.com/short-two=s900', width: 900, height: 900 }
                        ]
                      }
                    }
                  }
                }
              }
            }]
          }
        },
        buttonBar: {
          reelActionBarViewModel: {
            buttonViewModels: [
              {
                likeButtonViewModel: {
                  likeButtonViewModel: {
                    toggleButtonViewModel: {
                      toggleButtonViewModel: {
                        defaultButtonViewModel: button('LIKE', '1.5M', 'like this video along with 1,534,210 other people'),
                        toggledButtonViewModel: button('LIKE', '1.5M', 'unlike')
                      }
                    },
                    likeStatusEntity: { likeStatus: 'INDIFFERENT' }
                  }
                }
              },
              { dislikeButtonViewModel: { dislikeButtonViewModel: { toggleButtonViewModel: { toggleButtonViewModel: { defaultButtonViewModel: button('DISLIKE', 'Dislike', 'Dislike this video') } } } } },
              button('MESSAGE_BUBBLE', '3.4K', 'View 3,456 comments'),
              button('SHARE', 'Share', 'Share')
            ]
          }
        }
      }
    }
  };
}

function reelWatch(id) {
  // SHORTID0001: renderers; SHORTID0002: view models (and not liked); SHORTID0003: renderers with
  // texts only (and not liked); others: no overlay at all.
  const overlays = { SHORTID0001: reelOverlayRenderers, SHORTID0002: reelOverlayViewModels, SHORTID0003: reelOverlayRenderersTextOnly };
  const overlay = overlays[id] ? overlays[id](id) : {};
  const likeStatus = id === 'SHORTID0002' || id === 'SHORTID0003' ? 'INDIFFERENT' : 'LIKE';
  return {
    responseContext: {},
    ...overlay,
    playerResponse: playerResponse(id),
    frameworkUpdates: {
      entityBatchUpdate: {
        mutations: [{
          entityKey: 'x',
          payload: { likeStatusEntity: { key: Buffer.from([0x0a, 11, ...Buffer.from(id)]).toString('base64'), likeStatus } }
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

// ---- comments: view models whose content arrives as frameworkUpdates entities, like YouTube's.

const watchNextContinuation = (token) => ({ continuationCommand: { token, request: 'CONTINUATION_REQUEST_TYPE_WATCH_NEXT' } });

function commentEntities(c) {
  const avatar = `https://yt3.ggpht.com/avatar-${c.id.toLowerCase()}=s88-c-k-c0x00ffffff-no-rj`;
  return [
    {
      entityKey: `ck-${c.id}`,
      type: 'ENTITY_MUTATION_TYPE_REPLACE',
      payload: {
        commentEntityPayload: {
          key: `ck-${c.id}`,
          properties: { commentId: c.id, content: { content: c.text }, publishedTime: c.published, replyLevel: c.level || 0 },
          author: { channelId: c.channelId || CH3, displayName: c.author, avatarThumbnailUrl: avatar, isCreator: !!c.creator, isVerified: false },
          // YouTube leaves the counts empty when there are none.
          toolbar: { likeCountNotliked: c.likes || '', likeCountLiked: c.likes || '1', replyCount: c.replies || '' },
          avatar: { image: { sources: [{ url: avatar, width: 88, height: 88 }] } }
        }
      }
    },
    {
      entityKey: `ts-${c.id}`,
      type: 'ENTITY_MUTATION_TYPE_REPLACE',
      payload: {
        engagementToolbarStateEntityPayload: {
          key: `ts-${c.id}`,
          heartState: c.hearted ? 'TOOLBAR_HEART_STATE_HEARTED' : 'TOOLBAR_HEART_STATE_UNHEARTED',
          likeState: 'TOOLBAR_LIKE_STATE_INDIFFERENT'
        }
      }
    }
  ];
}

// `replies`: a continuation token (the replies are loaded when the thread is opened) or an array of
// comments sent along with the thread ("prepopulated").
function commentThread(c, replies) {
  const thread = {
    commentViewModel: {
      commentViewModel: {
        commentId: c.id,
        commentKey: `ck-${c.id}`,
        toolbarStateKey: `ts-${c.id}`,
        toolbarSurfaceKey: `tf-${c.id}`,
        commentSurfaceKey: `cs-${c.id}`,
        ...(c.pinned ? { pinnedText: 'Pinned by Channel One' } : {})
      }
    },
    renderingPriority: c.level ? 'RENDERING_PRIORITY_UNKNOWN' : 'RENDERING_PRIORITY_LINKED_COMMENT',
    isModeratedElqComment: false
  };
  if (replies) {
    thread.replies = {
      commentRepliesRenderer: {
        subThreads: typeof replies === 'string'
          ? [{ continuationItemRenderer: { trigger: 'CONTINUATION_TRIGGER_ON_ITEM_SHOWN', continuationEndpoint: watchNextContinuation(replies) } }]
          : replies.map((r) => commentThread(r)),
        viewReplies: { buttonRenderer: { text: runs(`${c.replies} replies`) } },
        hideReplies: { buttonRenderer: { text: runs('Hide replies') } },
        targetId: `comment-replies-item-${c.id}`
      }
    };
  }
  return { commentThreadRenderer: thread };
}

const reply = (parent, n, extra = {}) => ({
  id: `${parent}.REPLY${n}`, author: `@replier${n}`, text: `Reply number ${n}`, published: n === 1 ? '1 hour ago' : `${n} hours ago`, level: 1, ...extra
});

const COMMENTS = {
  pinned: {
    id: 'UgxCOMMENT0001', author: '@channelone', channelId: CH1, creator: true, pinned: true, hearted: true,
    text: 'Thanks for watching!\nChapters are in the description.', published: '1 day ago', likes: '1.2K', replies: '2'
  },
  plain: { id: 'UgxCOMMENT0002', author: '@viewer', text: 'First!', published: '1 day ago (edited)' },
  busy: { id: 'UgxCOMMENT0003', author: '@talker', text: 'A question for everyone', published: '20 hours ago', likes: '31', replies: '3' },
  later: { id: 'UgxCOMMENT0004', author: '@latecomer', text: 'Still here in 2026', published: '2 hours ago', likes: '2' },
  answered: { id: 'UgxCOMMENT0005', author: '@asker', text: 'Which camera is this?', published: '1 hour ago', replies: '1' }
};

const REPLIES = {
  [COMMENTS.pinned.id]: [reply(COMMENTS.pinned.id, 1, { likes: '12' }), reply(COMMENTS.pinned.id, 2, { author: '@channelone', channelId: CH1, creator: true })],
  [COMMENTS.busy.id]: [reply(COMMENTS.busy.id, 1), reply(COMMENTS.busy.id, 2)],
  // The next batch repeats the last reply of the first one, as YouTube does at batch edges.
  busyMore: [reply(COMMENTS.busy.id, 2), reply(COMMENTS.busy.id, 3)],
  [COMMENTS.answered.id]: [reply(COMMENTS.answered.id, 1, { author: '@channelone', channelId: CH1, creator: true })]
};

const commentsHeader = () => ({
  commentsHeaderRenderer: {
    countText: { runs: [{ text: '1,234' }, { text: ' Comments' }] },
    commentsCount: simple('1.2K'),
    titleText: runs('Comments')
  }
});

function commentsFirstPage() {
  const threads = [
    commentThread(COMMENTS.pinned, `REPLIES_${COMMENTS.pinned.id}`),
    commentThread(COMMENTS.plain),
    commentThread(COMMENTS.busy, `REPLIES_${COMMENTS.busy.id}`)
  ];
  return {
    responseContext: {},
    onResponseReceivedEndpoints: [
      { reloadContinuationItemsCommand: { targetId: 'comments-section', slot: 'RELOAD_CONTINUATION_SLOT_HEADER', continuationItems: [commentsHeader()] } },
      {
        reloadContinuationItemsCommand: {
          targetId: 'comments-section',
          slot: 'RELOAD_CONTINUATION_SLOT_BODY',
          continuationItems: [...threads, { continuationItemRenderer: { trigger: 'CONTINUATION_TRIGGER_ON_ITEM_SHOWN', continuationEndpoint: watchNextContinuation('COMMENTSCONT2') } }]
        }
      }
    ],
    frameworkUpdates: { entityBatchUpdate: { mutations: [COMMENTS.pinned, COMMENTS.plain, COMMENTS.busy].flatMap(commentEntities) } }
  };
}

function commentsSecondPage() {
  return {
    responseContext: {},
    onResponseReceivedEndpoints: [{
      appendContinuationItemsAction: {
        targetId: 'comments-section',
        // The pinned comment again (YouTube repeats it at page edges), and a thread whose reply
        // came along.
        continuationItems: [
          commentThread(COMMENTS.pinned, `REPLIES_${COMMENTS.pinned.id}`),
          commentThread(COMMENTS.later),
          commentThread(COMMENTS.answered, REPLIES[COMMENTS.answered.id])
        ]
      }
    }],
    frameworkUpdates: {
      entityBatchUpdate: { mutations: [COMMENTS.pinned, COMMENTS.later, COMMENTS.answered, ...REPLIES[COMMENTS.answered.id]].flatMap(commentEntities) }
    }
  };
}

function repliesResponse(parentId, replies, moreToken) {
  const items = replies.map((r) => commentThread(r));
  if (moreToken) {
    items.push({
      continuationItemRenderer: {
        trigger: 'CONTINUATION_TRIGGER_ON_ITEM_SHOWN',
        button: { buttonRenderer: { text: runs('Show more replies'), command: watchNextContinuation(moreToken) } }
      }
    });
  }
  return {
    responseContext: {},
    onResponseReceivedEndpoints: [{ appendContinuationItemsAction: { targetId: `comment-replies-item-${parentId}`, continuationItems: items } }],
    frameworkUpdates: { entityBatchUpdate: { mutations: replies.flatMap(commentEntities) } }
  };
}

// `/next` with a continuation token: the comment section (its first token is the protobuf YouTube.js
// builds), its next page, and reply batches. options.failTokens answers those tokens with 500.
function commentsRoute(token, options) {
  if ((options.failTokens || []).includes(token)) return { status: 500, body: { error: { code: 500, message: 'Internal error' } } };
  if (token === 'COMMENTSCONT2') return { status: 200, body: commentsSecondPage() };
  if (token === `REPLIES_${COMMENTS.pinned.id}`) return { status: 200, body: repliesResponse(COMMENTS.pinned.id, REPLIES[COMMENTS.pinned.id]) };
  if (token === `REPLIES_${COMMENTS.busy.id}`) return { status: 200, body: repliesResponse(COMMENTS.busy.id, REPLIES[COMMENTS.busy.id], 'REPLIESMORE_BUSY') };
  if (token === 'REPLIESMORE_BUSY') return { status: 200, body: repliesResponse(COMMENTS.busy.id, REPLIES.busyMore) };
  // options.commentsOff: a video with comments turned off answers without a comment section.
  if (options.commentsOff) return { status: 200, body: { responseContext: {} } };
  return { status: 200, body: commentsFirstPage() };
}

export const COMMENT_IDS = Object.fromEntries(Object.entries(COMMENTS).map(([name, c]) => [name, c.id]));

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
    if (path === `/s/player/${PLAYER_ID}/player_es6.vflset/en_US/base.js`) {
      // options.brokenPlayer: a player script the n/sig extractor finds nothing in.
      const js = options.brokenPlayer ? 'var _yt_player = {}; (function (g) { g.x = 1; })(_yt_player);' : playerJs;
      return { status: 200, body: js, headers: { 'content-type': 'text/javascript' } };
    }
    if (path === '/youtubei/v1/account/accounts_list') {
      if (!req.headers.cookie) return { status: 401, body: { error: { code: 401 } } };
      return { status: 200, body: accountsList() };
    }
    if (path === '/youtubei/v1/browse') {
      if (body?.continuation === 'HOMECONT1') return { status: 200, body: homeContinuation() };
      if (body?.continuation === 'SUBSCONT1') {
        return {
          status: 200,
          body: appendItems([
            richItem(lockupView({ id: 'SUBSVIDEO02', title: 'Older subscribed video', rows: [[{ text: 'Channel One', browseId: CH1 }], ['7K views', '2 days ago']] })),
            // A channel whose name reads like a live or upcoming stat.
            richItem(lockupView({ id: 'SUBSVIDEO03', title: 'Owls at dusk', rows: [[{ text: 'Bird Watching', browseId: CH3 }], ['300 views', '5 days ago']] }))
          ])
        };
      }
      if (body?.continuation === 'CHANCONT1') return { status: 200, body: appendItems([channelShelf(subscribedChannel(CH3, 'Channel Three', '300 subscribers'))]) };
      if (body?.continuation === 'PLAGGCONT1') {
        return {
          status: 200,
          body: appendItems([
            richItem(lockupView({ id: 'PLmine000002', type: 'PLAYLIST', title: 'Another list', badge: '1 video', rows: [['Unlisted', 'Playlist'], ['Updated today'], ['View full playlist']] })),
            // A saved Mix: not a playlist page, so Library → Playlists leaves it out.
            richItem(lockupView({
              id: 'RDMIXSAVED01', type: 'PLAYLIST', title: 'Mix – Channel Two', badge: 'Mix', rows: [['Channel Two and more'], ['Updated today']],
              onTap: { watchEndpoint: { videoId: 'MIXSAVEDVID', playlistId: 'RDMIXSAVED01' } }
            }))
          ])
        };
      }
      if (body?.browseId === 'FEwhat_to_watch') return { status: 200, body: homeBrowse() };
      if (body?.browseId === 'FEchannels') {
        if (options.channelsFeed === 'broken') return { status: 200, body: { responseContext: {} } };
        return { status: 200, body: channelsBrowse() };
      }
      if (body?.browseId === 'FEsubscriptions') return { status: 200, body: subscriptionsBrowse() };
      if (body?.browseId === 'FEplaylist_aggregation') return { status: 200, body: playlistsBrowse() };
      if (body?.browseId === 'VLWL') return { status: 200, body: watchLaterBrowse() };
      if (body?.browseId === CH1 || body?.browseId === CH2) return { status: 200, body: channelBrowse(body.browseId, body.params) };
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
      // options.expiresInSeconds: lifetime of the stream URLs; options.reorderClients: client names
      // that list the formats in another order.
      return {
        status: 200,
        body: playerResponse(body.videoId, {
          expiresInSeconds: options.expiresInSeconds,
          reversed: (options.reorderClients || []).includes(clientName),
          client: clientName
        })
      };
    }
    // googlevideo: options.refuseStreams lists clients whose stream URLs are answered with 403.
    if (path === '/videoplayback') {
      if ((options.refuseStreams || []).includes(url.searchParams.get('fakeclient'))) return { status: 403, body: '' };
      return { status: 206, body: 'x', headers: { 'content-type': 'video/webm' } };
    }
    if (path === '/youtubei/v1/next' && body?.continuation) return commentsRoute(decodeURIComponent(body.continuation), options);
    if (path === '/youtubei/v1/next') return { status: 200, body: nextResponse(body.videoId) };
    if (path === '/youtubei/v1/search') return { status: 200, body: searchResponse() };
    if (path === '/complete/search') return { status: 200, body: 'window.google.ac.h(["q",[["query one",0],["query two",0,[512]]],{"k":1}])', headers: { 'content-type': 'text/javascript' } };
    if (path === '/youtubei/v1/reel/reel_item_watch') return { status: 200, body: reelWatch(body.playerRequest?.videoId || body.videoId || 'SHORTID0001') };
    if (path === '/youtubei/v1/reel/reel_watch_sequence') return { status: 200, body: reelSequence() };
    if (path.startsWith('/api/stats/')) return { status: 204, body: '' };
    if (path === '/youtubei/v1/like/like' || path === '/youtubei/v1/like/dislike' || path === '/youtubei/v1/like/removelike') return { status: 200, body: { responseContext: {} } };
    if (path === '/youtubei/v1/subscription/subscribe' || path === '/youtubei/v1/subscription/unsubscribe') return { status: 200, body: { responseContext: {} } };
    if (path === '/youtubei/v1/browse/edit_playlist') {
      // options.editPlaylist 'failed': YouTube answers 200 but did not apply the edit.
      return { status: 200, body: { responseContext: {}, status: options.editPlaylist === 'failed' ? 'STATUS_FAILED' : 'STATUS_SUCCEEDED', actions: [] } };
    }
    return { status: 404, body: { error: `unmocked ${path}` } };
  };
  return { router, hits };
}
