import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));

test('process guard preserves handoffs and cleans only ended families', async (t) => {
  const temporary = await mkdtemp(join(tmpdir(), 'pufflet-guard-test-'));
  try {
    const probe = join(temporary, 'probe');
    execFileSync('cc', ['-std=c11', '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter',
      '-I' + join(root, 'Tests/Fixtures/guard-win32'),
      join(root, 'Tests/Fixtures/guard-lifetime.c'), '-o', probe]);
    for (const scenario of [
      'handoff', 'reverse', 'handoff-helper', 'family-exit', 'multiple', 'nested',
      'unknown-image', 'query-retry', 'late-bootstrap-classification', 'unknown-worker', 'unrecognized-helper', 'cleanup',
      'pid-reuse', 'missed-bootstrap', 'late-child', 'failed-snapshot', 'failed-enumeration',
      'failed-open', 'failed-times', 'failed-duplicate', 'capacity'
    ]) {
      await t.test(scenario, () => execFileSync(probe, [scenario], { stdio: 'pipe', timeout: 5000 }));
    }
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
});
