import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { createRequire } from 'node:module';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const require = createRequire(new URL('../../site/package.json', import.meta.url));
const site = fileURLToPath(new URL('../../site', import.meta.url));

export function r2Credentials(env, run = spawnSync) {
  const token = env.CLOUDFLARE_API_TOKEN;
  if (!token) throw new Error('CLOUDFLARE_API_TOKEN is required.');
  // R2 uses the token ID and SHA-256 of its value as S3 credentials.
  for (const owner of ['user', 'accounts']) {
    const result = run(`${site}/node_modules/.bin/cf`, [owner, 'tokens', 'verify'], {
      cwd: site, env, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 30_000,
    });
    if (result.status !== 0) continue;
    try {
      const document = JSON.parse(result.stdout);
      const verified = document.result ?? document;
      if (verified.status === 'active' && /^[a-f0-9]{32}$/.test(verified.id)) {
        return { accessKeyId: verified.id, secretAccessKey: createHash('sha256').update(token).digest('hex') };
      }
    } catch { /* Never include credential-command output in an error. */ }
  }
  throw new Error('Could not verify the Cloudflare CI token for R2 uploads.');
}

export function cloudflareUploader(env = process.env) {
  const bucket = env.R2_RELEASE_BUCKET ?? 'pufflet-releases';
  if (!/^[a-z0-9][a-z0-9-]{1,62}$/.test(bucket)) throw new Error('Invalid bucket name.');
  if (!/^[a-f0-9]{32}$/.test(env.CLOUDFLARE_ACCOUNT_ID ?? '')) throw new Error('CLOUDFLARE_ACCOUNT_ID is required.');
  const { S3Client } = require('@aws-sdk/client-s3');
  const { Upload } = require('@aws-sdk/lib-storage');
  const client = new S3Client({
    region: 'auto', endpoint: `https://${env.CLOUDFLARE_ACCOUNT_ID}.r2.cloudflarestorage.com`,
    credentials: r2Credentials(env), requestChecksumCalculation: 'WHEN_REQUIRED', responseChecksumValidation: 'WHEN_REQUIRED',
  });
  return async (key, file, contentType, cacheControl) => {
    try {
      await new Upload({
        client, params: { Bucket: bucket, Key: key, Body: createReadStream(file), ContentType: contentType, CacheControl: cacheControl },
        partSize: 32 * 1024 * 1024, queueSize: 3, leavePartsOnError: false,
      }).done();
    } catch {
      throw new Error(`R2 upload failed: ${key}`);
    }
  };
}
