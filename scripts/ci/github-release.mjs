import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, join } from 'node:path';

export const githubRepository = 'talhabalaj/pufflet';
export const githubDownloads = `https://github.com/${githubRepository}/releases`;

// Never log gh's captured output: authenticated API errors can contain URLs.
function gh(args, allowMissing = false) {
  try { return execFileSync('gh', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: 1024 * 1024 }); }
  catch (error) {
    if (allowMissing && /HTTP 404/.test(String(error.stderr))) return null;
    throw new Error(`GitHub release command failed (${args.slice(0, 2).join(' ')}).`);
  }
}

export function githubReleaseStore({ run = gh } = {}) {
  let release, tag;
  const inspect = () => JSON.parse(run(['api', `repos/${githubRepository}/releases/tags/${tag}`], true) ?? 'null');
  return {
    async begin(version, commitSha) {
      tag = `v${version}`;
      const remoteCommit = run(['api', `repos/${githubRepository}/commits/${tag}`, '--jq', '.sha'])?.trim();
      if (remoteCommit !== commitSha) throw new Error('Release tag does not point to the verified source commit.');
      release = inspect();
      if (!release) {
        run(['release', 'create', tag, '--repo', githubRepository, '--verify-tag', '--target', commitSha,
          '--draft', '--latest=false', '--title', `Pufflet ${version}`, '--notes', 'Developer ID signed and notarized macOS release.']);
        release = inspect();
      }
      if (!release || release.prerelease || release.target_commitish !== commitSha) throw new Error('Existing release has unexpected source or prerelease status.');
    },
    async read(name) {
      release = inspect();
      if (!release.assets.some(asset => asset.name === name)) return new Response(null, { status: 404 });
      const directory = mkdtempSync(join(tmpdir(), 'pufflet-release-'));
      try {
        if (run(['release', 'download', tag, '--repo', githubRepository, '--pattern', name, '--dir', directory]) === null) throw new Error('Could not read the existing release asset.');
        return new Response(readFileSync(join(directory, name)));
      } finally { rmSync(directory, { recursive: true, force: true }); }
    },
    async put(name, file) {
      if (!release.is_draft && !release.draft) throw new Error('Refusing to add assets to a published release.');
      if (basename(file) !== name) throw new Error('Release asset filename mismatch.');
      run(['release', 'upload', tag, file, '--repo', githubRepository]); // No --clobber.
    },
    async publish() { if (inspect().draft) run(['release', 'edit', tag, '--repo', githubRepository, '--draft=false', '--latest=false']); },
    async promote() { run(['release', 'edit', tag, '--repo', githubRepository, '--latest']); },
  };
}
