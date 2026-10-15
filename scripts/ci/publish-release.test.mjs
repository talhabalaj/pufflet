import assert from 'node:assert/strict';
import { createHash, createPublicKey, generateKeyPairSync, sign } from 'node:crypto';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { afterEach, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { publishRelease, repoRoot, verifySignedFeed } from './publish-release.mjs';
import { releaseFiles } from './release-files.mjs';

const temporary = [];
afterEach(() => { for (const directory of temporary.splice(0)) rmSync(directory, { recursive: true, force: true }); });

function signedFeed(content, privateKey) {
  const data = Buffer.from(content);
  return `${content}<!-- sparkle-signatures:\nedSignature: ${sign(null, data, privateKey).toString('base64')}\nlength: ${data.length}\n-->\n`;
}

function fixture() {
  const output = mkdtempSync(join(tmpdir(), 'superscribe-publisher-test-'));
  temporary.push(output);
  const keys = generateKeyPairSync('ed25519');
  const publicKey = keys.publicKey.export({ type: 'spki', format: 'der' }).subarray(-32).toString('base64');
  const archive = Buffer.from('signed archive fixture');
  const metadata = {
    version: '1.1', build: '20261005.1', minimumMacOS: '27.0', bytes: archive.length,
    sha256: createHash('sha256').update(archive).digest('hex'),
    signature: sign(null, archive, keys.privateKey).toString('base64'),
    commitSha: 'b'.repeat(40), architecture: 'arm64', cloudBuildId: 'build', artifactId: 'artifact',
  };
  const { manifest, appcast } = releaseFiles(metadata);
  const feed = signedFeed(appcast, keys.privateKey);
  writeFileSync(join(output, 'manifest.json'), JSON.stringify(manifest));
  writeFileSync(join(output, 'metadata.json'), JSON.stringify(metadata));
  writeFileSync(join(output, manifest.file), archive);
  writeFileSync(join(output, `${manifest.file}.sha256`), `${manifest.sha256}  ${manifest.file}\n`);
  writeFileSync(join(output, 'appcast.xml'), feed);
  const older = { version: '1.0', build: '20261004.1', file: 'Pufflet-1.0-20261004.1.zip', sha256: 'c'.repeat(64) };
  const store = new Map([['downloads/manifest.json', Buffer.from(JSON.stringify(older))]]);
  const events = [];
  const hooks = {};
  const fetch = async url => {
    const path = new URL(url).pathname.slice(1);
    events.push(`read:${path}`);
    const override = await hooks.read?.(path);
    if (override) return override;
    const content = store.get(path);
    return content ? new Response(content) : new Response(null, { status: 404 });
  };
  const put = async (key, file) => {
    events.push(`write:${key}`);
    if (await hooks.write?.(key, file)) return;
    store.set(key, readFileSync(file));
  };
  return { output, publicKey, archive, manifest, metadata, appcast, feed, keys, store, events, hooks,
    publish: () => publishRelease(output, { publicKey, fetch, put }),
    writes: () => events.filter(event => event.startsWith('write:')),
  };
}

test('resolves the pinned CLI from the repository root', () => {
  assert.equal(resolve(repoRoot), fileURLToPath(new URL('../..', import.meta.url)).replace(/\/$/, ''));
  assert.ok(existsSync(join(repoRoot, 'site/cloudflare.config.ts')));
});

test('validates a real Ed25519 feed in Sparkle 2.10 format including UTF-8 length', () => {
  const f = fixture();
  const unicode = signedFeed('<rss>日本語</rss>\n', f.keys.privateKey);
  assert.equal(verifySignedFeed(Buffer.from(unicode), f.keys.publicKey), '<rss>日本語</rss>\n');
  assert.throws(() => verifySignedFeed(Buffer.from(unicode.replace('日本語', 'changed')), f.keys.publicKey), /verification/);
  const key = createPublicKey({ key: f.keys.publicKey.export({ type: 'spki', format: 'der' }), format: 'der', type: 'spki' });
  assert.equal(verifySignedFeed(Buffer.from(f.feed), key), f.appcast);
});

test('publishes renamed archives over a historical manifest and writes the verified feed last', async () => {
  const f = fixture();
  const historical = JSON.parse(f.store.get('downloads/manifest.json'));
  assert.match(historical.file, /^Pufflet-/);
  assert.match(f.manifest.file, /^Pufflet-/);
  const result = await f.publish();
  const archiveKey = `downloads/${f.manifest.file}`;
  assert.deepEqual(f.writes(), [`write:${archiveKey}`, `write:${archiveKey}.sha256`, 'write:downloads/manifest.json', 'write:appcast.xml']);
  const manifestWrite = f.events.indexOf('write:downloads/manifest.json');
  assert.ok(f.events.slice(0, manifestWrite).filter(event => event === `read:${archiveKey}`).length >= 2);
  assert.equal(f.events[f.events.indexOf('write:appcast.xml') - 1], 'read:downloads/manifest.json');
  assert.equal(f.events.at(-1), 'read:appcast.xml');
  assert.equal(result.build, f.manifest.build);
  assert.equal(result.download, `https://pufflet.apps.balaj.me/downloads/${f.manifest.file}`);
  assert.equal(result.feed, 'https://pufflet.apps.balaj.me/appcast.xml');
  assert.ok(existsSync(join(f.output, 'publication.json')));
});

test('accepts the expanded empty enclosure emitted by official sign_update XML serialization', async () => {
  const f = fixture();
  const serialized = f.appcast.replace(/(<enclosure[^>]+) \/>/, '$1></enclosure>');
  assert.match(serialized, /<\/enclosure>/);
  writeFileSync(join(f.output, 'appcast.xml'), signedFeed(serialized, f.keys.privateKey));
  assert.equal((await f.publish()).build, f.manifest.build);
});

test('refuses to overwrite an orphaned immutable archive even without version metadata', async () => {
  const f = fixture();
  f.store.set(`downloads/${f.manifest.file}`, Buffer.from('an earlier different archive'));
  await assert.rejects(f.publish(), /hash or size/);
  assert.deepEqual(f.writes(), []);
});

test('retries matching immutable artifacts without rewriting them', async () => {
  const f = fixture();
  f.store.set(`downloads/${f.manifest.file}`, f.archive);
  f.store.set(`downloads/${f.manifest.file}.sha256`, readFileSync(join(f.output, `${f.manifest.file}.sha256`)));
  await f.publish();
  assert.deepEqual(f.writes(), ['write:downloads/manifest.json', 'write:appcast.xml']);
});

test('rejects an older build and a different archive at the currently published build', async () => {
  for (const current of [{ build: '20261006.1', sha256: 'd'.repeat(64) }, { build: '20261005.1', sha256: 'd'.repeat(64) }]) {
    const f = fixture();
    f.store.set('downloads/manifest.json', Buffer.from(JSON.stringify(current)));
    await assert.rejects(f.publish(), /newer release|different archive/);
    assert.deepEqual(f.writes(), []);
  }
});

test('rechecks the current build before promotion to prevent stale publication', async () => {
  const f = fixture();
  let manifestReads = 0;
  f.hooks.read = path => {
    if (path === 'downloads/manifest.json' && ++manifestReads === 2) return new Response(JSON.stringify({ build: '20261006.1', sha256: 'd'.repeat(64) }));
  };
  await assert.rejects(f.publish(), /newer release/);
  assert.ok(f.writes().every(event => !['write:downloads/manifest.json', 'write:appcast.xml'].includes(event)));
});

test('upload failures and a corrupt public download never promote manifest or feed', async () => {
  for (const failure of ['archive', 'checksum', 'corrupt']) {
    const f = fixture();
    f.hooks.write = key => {
      if (failure === 'archive' && key.endsWith('.zip') || failure === 'checksum' && key.endsWith('.sha256')) throw new Error('mock CLI upload failed');
      if (failure === 'corrupt' && key.endsWith('.zip')) { f.store.set(key, Buffer.from('corrupt')); return true; }
    };
    await assert.rejects(f.publish(), /upload failed|hash or size/);
    assert.ok(f.writes().every(event => !['write:downloads/manifest.json', 'write:appcast.xml'].includes(event)));
    assert.equal(existsSync(join(f.output, 'publication.json')), false);
  }
});

test('a failed manifest write or public manifest mismatch never promotes the feed', async () => {
  for (const failure of ['write', 'verification']) {
    const f = fixture();
    f.hooks.write = key => {
      if (key !== 'downloads/manifest.json') return;
      if (failure === 'write') throw new Error('mock CLI upload failed');
      return true; // Simulate a successful upload whose public content stays old.
    };
    await assert.rejects(f.publish(), /upload failed|Published manifest/);
    assert.ok(!f.writes().includes('write:appcast.xml'));
    assert.equal(existsSync(join(f.output, 'publication.json')), false);
  }
});

test('feed upload or public feed verification failure does not report successful publication', async () => {
  for (const failure of ['write', 'verification']) {
    const f = fixture();
    f.hooks.write = key => {
      if (key !== 'appcast.xml') return;
      if (failure === 'write') throw new Error('mock CLI upload failed');
      f.store.set(key, Buffer.from('different feed')); return true;
    };
    await assert.rejects(f.publish(), /upload failed|Published appcast/);
    assert.equal(existsSync(join(f.output, 'publication.json')), false);
  }
});

test('unsigned, tampered, mismatched, and differently keyed feeds fail before network operations', async () => {
  for (const failure of ['unsigned', 'tampered', 'mismatch', 'wrong-key']) {
    const f = fixture();
    if (failure === 'unsigned') writeFileSync(join(f.output, 'appcast.xml'), f.appcast);
    if (failure === 'tampered') writeFileSync(join(f.output, 'appcast.xml'), f.feed.replace('Pufflet Updates', 'Altered Updates'));
    if (failure === 'mismatch') writeFileSync(join(f.output, 'appcast.xml'), signedFeed(f.appcast.replace('<sparkle:version>20261005.1</sparkle:version>', '<sparkle:version>20261003.1</sparkle:version>'), f.keys.privateKey));
    const differentKey = generateKeyPairSync('ed25519').publicKey.export({ type: 'spki', format: 'der' }).subarray(-32).toString('base64');
    await assert.rejects(failure === 'wrong-key' ? publishRelease(f.output, { publicKey: differentKey, fetch: () => assert.fail('Network must not be called'), put: () => assert.fail('CLI must not be called') }) : f.publish(), /signed by Sparkle|verification|describe the verified archive/);
    assert.deepEqual(f.events, []);
  }
});

 test('publishes the first release when no manifest exists', async () => { const f=fixture(); f.store.delete('downloads/manifest.json'); await f.publish(); assert.equal(f.writes().at(-1),'write:appcast.xml'); });
