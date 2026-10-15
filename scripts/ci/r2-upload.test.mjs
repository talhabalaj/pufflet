import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import test from 'node:test';
import { r2Credentials, cloudflareUploader } from './r2-upload.mjs';

const env = { CLOUDFLARE_API_TOKEN: 'test-only-token', CLOUDFLARE_ACCOUNT_ID: 'a'.repeat(32) };
const id = 'b'.repeat(32);

test('R2 derives S3 credentials from the verified existing token without logging it', () => {
  const calls = [];
  const credentials = r2Credentials(env, (command, args, options) => {
    calls.push(args);
    assert.match(command, /site\/node_modules\/\.bin\/cf$/);
    assert.deepEqual(options.stdio, ['ignore', 'pipe', 'pipe']);
    assert.equal(options.env.CLOUDFLARE_API_TOKEN, env.CLOUDFLARE_API_TOKEN);
    assert.equal(args.includes(env.CLOUDFLARE_API_TOKEN), false);
    return { status: 0, stdout: JSON.stringify({ result: { id, status: 'active' } }) };
  });
  assert.deepEqual(calls, [['user', 'tokens', 'verify']]);
  assert.deepEqual(credentials, { accessKeyId: id, secretAccessKey: createHash('sha256').update(env.CLOUDFLARE_API_TOKEN).digest('hex') });
});

test('R2 supports account-owned tokens and fails closed on invalid verification without exposing output', () => {
  const calls = [];
  assert.equal(r2Credentials(env, (_, args) => {
    calls.push(args);
    return args[0] === 'user' ? { status: 1, stderr: env.CLOUDFLARE_API_TOKEN }
      : { status: 0, stdout: JSON.stringify({ id, status: 'active' }) };
  }).accessKeyId, id);
  assert.equal(calls.length, 2);
  for (const result of [
    { status: 1, stderr: env.CLOUDFLARE_API_TOKEN },
    { status: 0, stdout: env.CLOUDFLARE_API_TOKEN },
    { status: 0, stdout: JSON.stringify({ id, status: 'disabled' }) },
    { status: 0, stdout: JSON.stringify({ id: '../invalid', status: 'active' }) },
  ]) assert.throws(() => r2Credentials(env, () => result), { message: 'Could not verify the Cloudflare CI token for R2 uploads.' });
  assert.throws(() => r2Credentials({}), /CLOUDFLARE_API_TOKEN is required/);
  assert.throws(() => cloudflareUploader({ ...env, R2_RELEASE_BUCKET: '../wrong' }), /Invalid bucket name/);
  assert.throws(() => cloudflareUploader({ ...env, CLOUDFLARE_ACCOUNT_ID: 'wrong' }), /CLOUDFLARE_ACCOUNT_ID is required/);
});
