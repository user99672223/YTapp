import { Innertube } from 'youtubei.js/web';

globalThis.TubeBridge = {
  bundleInfo: {
    bundleVersion: __BUNDLE_VERSION__,
    youtubeiVersion: __YOUTUBEI_VERSION__,
    bgutilsVersion: __BGUTILS_VERSION__
  },
  hasInnertube: typeof Innertube === 'function'
};
