import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const bundlePath = new URL('../../App/Resources/js/youtubei.bundle.js', import.meta.url);

test('bundle loads in a bare context', () => {
  const code = readFileSync(bundlePath, 'utf8');
  const context = vm.createContext({});
  vm.runInContext(code, context);
  assert.equal(typeof context.TubeBridge, 'object');
  assert.equal(context.TubeBridge.hasInnertube, true);
});
