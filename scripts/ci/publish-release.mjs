import { createHash, createPublicKey, verify } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { isDeepStrictEqual } from 'node:util';
import { releaseOrigin, releaseFiles } from './release-files.mjs';
import { cloudflareUploader } from './r2-upload.mjs';

export const repoRoot = fileURLToPath(new URL('../..', import.meta.url));
const immutableCache = 'public, max-age=31536000, immutable';
const buildPattern = /^\d+(?:\.\d+){0,2}$/;
const freshRequest = { cache: 'no-store', headers: { 'Cache-Control': 'no-cache' } };

function compareBuilds(left, right) {
  const a = left.split('.').map(BigInt), b = right.split('.').map(BigInt);
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    if ((a[i] ?? 0n) !== (b[i] ?? 0n)) return (a[i] ?? 0n) > (b[i] ?? 0n) ? 1 : -1;
  }
  return 0;
}

function requireForwardRelease(manifest, current) {
  if (current === null) return;
  if (!buildPattern.test(current?.build ?? '') || !/^[a-f0-9]{64}$/.test(current?.sha256 ?? '')) throw new Error('Current release manifest is invalid.');
  const comparison = compareBuilds(manifest.build, current.build);
  if (comparison < 0) throw new Error('Refusing to replace a newer release with an older build.');
  if (comparison === 0 && (current.sha256 !== manifest.sha256 || current.file !== manifest.file)) throw new Error('A different archive already uses this build number.');
}

function publicSigningKey(value) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9+/]{43}=$/.test(value) || Buffer.from(value, 'base64').length !== 32) throw new Error('SPARKLE_PUBLIC_KEY must contain the release public Ed25519 key.');
  return createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), Buffer.from(value, 'base64')]), type: 'spki', format: 'der' });
}

// Sparkle 2.10 appends this exact comment block, and signs the bytes BEFORE it.
// Validate its real signature rather than mistaking an enclosure for a signed feed.
export function verifySignedFeed(feed, key) {
  const text = feed.toString('utf8');
  const block = /<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/]{86}==)\nlength: ([0-9]+)\n-->\n?$/.exec(text);
  if (!block) throw new Error('The appcast must be signed by Sparkle before publishing.');
  const content = Buffer.from(text.slice(0, block.index), 'utf8');
  if (String(content.length) !== block[2] || !verify(null, content, key, Buffer.from(block[1], 'base64'))) throw new Error('The signed appcast failed Ed25519 verification.');
  return content.toString('utf8');
}

function requireMatchingFeed(content, manifest, metadata) {
  const enclosures = [...content.matchAll(/<enclosure\s+([^>]+)>/g)];
  const attribute = name => new RegExp(`(?:^|\\s)${name}="([^"]+)"`).exec(enclosures[0]?.[1] ?? '')?.[1];
  if (enclosures.length !== 1 || attribute('url') !== `${releaseOrigin}/downloads/${manifest.file}` ||
      attribute('sparkle:edSignature') !== metadata.signature || attribute('length') !== String(manifest.bytes) ||
      !content.includes(`<sparkle:version>${manifest.build}</sparkle:version>`) ||
      !content.includes(`<sparkle:shortVersionString>${manifest.version}</sparkle:shortVersionString>`)) {
    throw new Error('Signed feed does not describe the verified archive.');
  }
}

async function verifyDownload(response, manifest) {
  if (!response.ok || !response.body) throw new Error(`Public download failed: HTTP ${response.status}`);
  const hash = createHash('sha256');
  let bytes = 0;
  for await (const chunk of response.body) { hash.update(chunk); bytes += chunk.length; }
  if (hash.digest('hex') !== manifest.sha256 || bytes !== manifest.bytes) throw new Error('Public archive hash or size does not match the verified release.');
}

export async function publishRelease(outputDirectory, { fetch: fetchRelease = globalThis.fetch, put, publicKey = process.env.SPARKLE_PUBLIC_KEY } = {}) {
  const output = resolve(outputDirectory);
  const manifest = JSON.parse(readFileSync(join(output, 'manifest.json'), 'utf8'));
  const metadata = JSON.parse(readFileSync(join(output, 'metadata.json'), 'utf8'));
  if (!isDeepStrictEqual(releaseFiles(metadata).manifest, manifest)) throw new Error('Manifest does not match validated release metadata.');
  const archivePath = join(output, manifest.file);
  const archive = readFileSync(archivePath);
  if (archive.length !== manifest.bytes || createHash('sha256').update(archive).digest('hex') !== manifest.sha256) throw new Error('Archive hash or size changed after verification.');
  const key = publicSigningKey(publicKey);
  if (!verify(null, archive, key, Buffer.from(metadata.signature, 'base64'))) throw new Error('Archive failed Ed25519 verification.');
  const feed = readFileSync(join(output, 'appcast.xml'));
  requireMatchingFeed(verifySignedFeed(feed, key), manifest, metadata);
  const checksumPath = join(output, `${manifest.file}.sha256`);
  const checksum = `${manifest.sha256}  ${manifest.file}\n`;
  if (readFileSync(checksumPath, 'utf8') !== checksum) throw new Error('Archive checksum file is invalid.');
  const upload = put ?? cloudflareUploader();
  const read = path => fetchRelease(`${releaseOrigin}/${path}`, freshRequest);
  const currentManifest = async () => {
    const response = await read('downloads/manifest.json');
    if (response.status === 404) return null;
    if (!response.ok) throw new Error('Could not verify the currently published build.');
    return response.json();
  };
  requireForwardRelease(manifest, await currentManifest());

  // CI serializes release publishers with a shared concurrency group. Inspect
  // the archive itself: an interrupted earlier run may not have a manifest.
  const downloadKey = `downloads/${manifest.file}`;
  const existing = await read(downloadKey);
  if (existing.status === 404) await upload(downloadKey, archivePath, 'application/zip', immutableCache);
  else await verifyDownload(existing, manifest); // Matching retries never overwrite immutable ZIPs.
  const checksumKey = `${downloadKey}.sha256`;
  const existingChecksum = await read(checksumKey);
  if (existingChecksum.status === 404) await upload(checksumKey, checksumPath, 'text/plain; charset=utf-8', immutableCache);
  else if (!existingChecksum.ok || await existingChecksum.text() !== checksum) throw new Error('An immutable checksum already exists with different content.');

  await verifyDownload(await read(downloadKey), manifest);
  // Recheck after uploads and public verification, immediately before promotion.
  requireForwardRelease(manifest, await currentManifest());
  await upload('downloads/manifest.json', join(output, 'manifest.json'), 'application/json', 'no-cache');
  const publishedManifest = await currentManifest();
  if (!isDeepStrictEqual(publishedManifest, manifest)) throw new Error('Published manifest differs from the verified release.');
  // The feed is the final write, so archive failures never advertise an update.
  await upload('appcast.xml', join(output, 'appcast.xml'), 'application/rss+xml; charset=utf-8', 'no-cache');
  const published = await read('appcast.xml');
  if (!published.ok || !Buffer.from(await published.arrayBuffer()).equals(feed)) throw new Error('Published appcast differs from the signed feed.');
  const publication = { build: manifest.build, sha256: manifest.sha256, download: `${releaseOrigin}/${downloadKey}`, feed: `${releaseOrigin}/appcast.xml`, verifiedAt: new Date().toISOString() };
  writeFileSync(join(output, 'publication.json'), JSON.stringify(publication, null, 2) + '\n');
  return publication;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const publication = await publishRelease(process.argv[2] ?? 'build/ci/release');
  console.log(`Published and verified Pufflet build ${publication.build}.`);
}
