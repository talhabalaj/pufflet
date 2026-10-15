import assert from 'node:assert/strict';
import test from 'node:test';
import { releaseDetails } from '../public/release.mjs';

const manifest = { version: '0.1.0', build: '2', file: 'Pufflet-0.1.0-2.zip', minimumMacOS: '26.0', architecture: 'arm64', notarized: true };
test('published notarized release enables the existing download route and displays manifest requirements', () => {
  assert.deepEqual(releaseDetails(manifest), { href: '/downloads/latest.zip', detail: 'Version 0.1.0 · Apple silicon · macOS 26.0 or later' });
});
test('missing, unsigned, malformed, and mismatched releases keep the first-release state', () => {
  for (const value of [null, {}, { ...manifest, notarized: false }, { ...manifest, notarized: 'true' },
    { ...manifest, file: 'https://example.com/other.zip' }, { ...manifest, file: '../Pufflet-0.1.0-2.zip' },
    { ...manifest, file: 'Pufflet-0.1.0-3.zip' }, { ...manifest, minimumMacOS: '<script>' },
    { ...manifest, architecture: 'x86_64' }, { ...manifest, version: 'bad' }, { ...manifest, build: 2 }]) {
    assert.equal(releaseDetails(value), null);
  }
});
