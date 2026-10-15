// Only a published, notarized manifest can turn the release links into downloads.
export function releaseDetails(manifest) {
  const version = value => typeof value === 'string' && /^\d+(?:\.\d+){0,2}$/.test(value);
  if (!manifest || manifest.notarized !== true || manifest.architecture !== 'arm64' ||
      !version(manifest.version) || !version(manifest.build) || !version(manifest.minimumMacOS) ||
      manifest.file !== `Pufflet-${manifest.version}-${manifest.build}.zip`) return null;
  return {
    href: '/downloads/latest.zip',
    detail: `Version ${manifest.version} · Apple silicon · macOS ${manifest.minimumMacOS} or later`,
  };
}
