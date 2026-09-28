// Bundle entry. Polyfills must be imported first so they exist before YouTube.js evaluates.
import './polyfills/index.js';
import { TubeBridge } from './bridge/index.js';
import { loadPlatform } from './bridge/platform.js';

loadPlatform();
globalThis.TubeBridge = TubeBridge;
