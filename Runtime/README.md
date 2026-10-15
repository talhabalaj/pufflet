# Downloaded Windows support

Ordinary app builds are offline with respect to Wine, DXMT and GStreamer. The
only native build-time runtime step, `bundle-runtime.sh`, copies and signs the
universal `Resources/libSteamLibraryDock.dylib` with Xcode’s
`EXPANDED_CODE_SIGN_IDENTITY`, Hardened Runtime, and no additional entitlements.
Release signing uses a timestamp; Debug does not. It deliberately does not invoke
`sign-runtime.py`. A marker from the previous bundled-runtime architecture allows
incremental builds to remove obsolete runtime output from the **built app only**.
Sparkle remains a normal embedded framework. The saved Pufflet icon and bundled
`dockhost.exe` are unchanged; no Dock source rebuild is needed during setup.

`bootstrap-runtime.sh`, `sign-runtime.py`, and `Wine.entitlements` remain manual
artifact-preparation helpers for the release pipeline, not app-build inputs.
The release setup owner maintains `scripts/ci/package-runtime.sh` and publication.

## Artifact contract

`Resources/RuntimeArtifact.json` is part of the signed app. It is the trust anchor;
there is no unsigned network manifest. The current schema is:

```json
{
  "schemaVersion": 1,
  "version": "wine-11.0-dxmt-1",
  "url": "https://github.com/talhabalaj/pufflet/releases/download/runtime-wine-11.0-dxmt-1/PuffletRuntime-wine-11.0-dxmt-1.tar.xz",
  "sha256": "<SHA-256 of final signed, stapled tar.xz, lowercase hex>",
  "sizeBytes": 123,
  "expandedSizeBytes": 456,
  "bundleName": "PuffletRuntime.app",
  "teamIdentifier": "W7TT249CUU"
}
```

The sizes above are examples, not publication values. `expandedSizeBytes` bounds
the sum of regular file lengths in the archive. Before publication, the release
owner must supply the actual hash and sizes from the final immutable archive.
An empty hash or zero size fails closed with a native setup error. Replacing an
asset under the same URL causes existing apps to reject it; a different artifact
needs a new version, URL and app pin. GitHub release redirects are permitted only
over HTTPS on standard ports to GitHub’s release-asset hosts. No credentials or
cookies are sent. The owned repository is the mirror, so installation does not
depend on upstream Sikarugir release availability.

The xz-compressed tar has exactly one top-level app:

```text
PuffletRuntime.app/
  Contents/
    Info.plist                  # me.balaj.Pufflet.Runtime
    MacOS/<native wrapper>      # universal, Developer ID, hardened runtime
    _CodeSignature/...
    CodeResources               # stapled ticket, when produced by stapler
    SharedSupport/
      wine/bin/{wine,wineserver}
      wine/{lib,lib64,...}
      renderer/dxmt/wine/...     # Windows DLLs, outside macOS Frameworks
    Frameworks/
      GStreamer.framework/...
      <flat native support libraries>
```

Sign all native Mach-O files inside-out using Developer ID team `W7TT249CUU`;
only Wine/wineserver receive `Wine.entitlements`. Seal the root wrapper app,
notarize and staple it, then archive without outside AppleDouble files or hard
links. Keep normal modes and internal relative framework symlinks; do not emit
archive members beneath symlink paths. Validate a freshly extracted archive with
strict/deep signature verification and Gatekeeper before publishing. Do not strip
quarantine, disable library validation, or bypass macOS protections.

## Installation and data ownership

Debug uses `~/Library/Application Support/PuffletDev`; Release uses `Pufflet`.
The installer keeps a global advisory lock in `Runtimes/.install.lock`, streams the
download to disk, and checks the exact size and SHA-256 **before parsing**. macOS’s
libarchive reads the verified tar twice with bounded memory. A minimal header
provides its stable read ABI because the SDK exposes the system library without
its C headers; no extra runtime extraction dependency is downloaded or bundled.

The first pass validates all entries and the complete symlink graph. Absolute
paths, dot traversal, case/Unicode-normalization collisions, backslashes, control
characters, hard links, devices, archive members below symlinks and chained link
escapes are rejected. Regular files/directories are written before symlinks;
expanded bytes and entry counts are bounded. Extraction strips setuid/setgid and
writable-by-group/world file permissions, while retaining executable bits.

Staging is private and on the same filesystem as the final version. The app checks
required Wine/renderer/framework paths, strict/deep signatures on all architectures
against a Developer ID Application certificate, its pinned team and wrapper
identifier, then asks Gatekeeper to approve
execution. Only afterward does it write a matching receipt and atomically rename
the staging directory to `Runtimes/<version>`. No active version is overwritten.
Cancellation/failure removes only that transaction’s staging data; the exclusive
lock also allows a later attempt to remove UUID-named stages left by a crash.

An existing version with the exact receipt, complete layout, valid signature and
Gatekeeper approval is reused without downloading, including offline. An existing
incomplete/conflicting version is preserved and reported, never silently replaced.
No automatic runtime garbage collection deletes older versions or active code.

The prefix (`prefix`), Steam session/Keychain data, external library, and saves are
never moved into the runtime. Native Steam components still download from Valve’s
official CDN through the existing package/hash checks. Neither signed-in Steam
data nor Valve binaries belong in the mirrored artifact. App update restarts wait
for a runtime installation as well as an active game session.

First-launch setup chooses the external library, starts installation with real
byte progress and cancel/retry, opens existing native authentication, and exposes
Steam-support preparation separately. It remains possible to browse the library
without installing or authenticating. Play and Steam preparation route back to
setup if runtime support is absent.

## Focused validation

```sh
xcodegen generate
xcodebuild -project SteamLibrary.xcodeproj -scheme SteamLibrary \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/RuntimeOnboarding test
node --test Tests/*.test.mjs
```

`RuntimeInstallerTests` uses local xz/tar fixtures to exercise the actual transaction;
only download transport and signature approval are substituted in success tests.
A separate test verifies that the real signature checker rejects an unsigned
fixture. These fixtures do not prove notarization or real Wine execution; the
published archive must also be checked with the production approval path.
