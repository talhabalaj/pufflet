import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';

const source = (path) => readFile(new URL(path, import.meta.url), 'utf8');

// Dock reports a long unpaused wait as a status; it must never end the install.
test('Dock emits install-no-progress as a non-terminal poll status', async () => {
  const install = await source('../Research/Madeira/Dock/src/install.c');
  const poll = install.slice(install.indexOf('int sh_install_poll('));
  assert.match(poll, /o->event\("install-no-progress", sh_install_unchanged_ms\(/);
  assert.doesNotMatch(poll, /install-no-progress[^;]*;\s*return/);
});

// Snapshot the event parser and report before compiling: no app, preferences,
// credentials, Wine or Steam processes are involved.
test('install-no-progress reaches the Downloads status and clears on progress', {
  skip: process.platform !== 'darwin',
}, async () => {
  const temporary = await mkdtemp('/private/tmp/pufflet-install-recovery-');
  try {
    const [host, session, fixture] = await Promise.all([
      source('../Sources/SteamAuth/SteamSessionHost.swift'),
      source('../Sources/SteamAuth/SteamHeadlessSession.swift'),
      source('./Fixtures/install-recovery.swift'),
    ]);
    const event = host.slice(host.indexOf('nonisolated struct SteamSessionEvent'), host.indexOf('nonisolated struct SteamSessionDecoder'));
    const report = session.slice(session.indexOf('nonisolated struct SteamHostReport'), session.indexOf('@Observable final class SteamHeadlessSession'));
    // Exercise the original behavior when the status does not exist yet.
    const baseline = report.includes('var installWaitStatus') ? '' : 'extension SteamHostReport { var installWaitStatus: String? { nil } }\n';
    await writeFile(join(temporary, 'main.swift'), 'import Foundation\n' + event + report + baseline + fixture);
    execFileSync('swiftc', ['-swift-version', '6', '-module-cache-path', join(temporary, 'modules'), join(temporary, 'main.swift'), '-o', join(temporary, 'probe')], { timeout: 60_000, stdio: 'pipe' });
    const result = spawnSync(join(temporary, 'probe'), { timeout: 10_000, encoding: 'utf8' });
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.match(result.stdout, /PASS: install recovery regressions/);
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
});
