# Pufflet builds and releases

This is the same release architecture as Said: Xcode Cloud creates a **STAPLED_NOTARIZED_ARCHIVE**, GitHub verifies it on macOS, Sparkle signs the archive/feed, and GitHub Releases stores versioned downloads served through `https://pufflet.apps.balaj.me`.

## Configured

- Public source repository: `talhabalaj/pufflet`.
- Shared Xcode project/scheme: `SteamLibrary.xcodeproj` / `SteamLibrary`.
- Developer team: `W7TT249CUU`; production identity `me.balaj.SteamLibrary`.
- Worker `pufflet-site`, custom domain `pufflet.apps.balaj.me`, GitHub release assets (no R2 runtime/download binding).
- Sparkle public verification key is committed in the app's typed Info.plist settings. The private key is held in Keychain and backed up in 1Password; CI uses an encrypted repository secret. No key belongs in source control.
- CI runs release-tooling tests, website types/build and script checks. Native tests run locally and in the Xcode Cloud release workflow.

## Cloud configuration

Pufflet is connected to Xcode Cloud product `33095b22-cf8f-444b-a4f1-85e42426f0cf`. The locked **Pufflet Release** workflow is `1732839D-8988-49DB-A36B-B50144059B79`, with required macOS Test and Archive actions, Xcode 27/macOS 27, and a Notarize post-action. GitHub's `XCODE_CLOUD_WORKFLOW_ID` points to it. Automatic starts are disabled; manual starts accept `v` tags. The initial Cloud counter is 2, above the local prototype's build 1.

The following steps document how to recreate the configuration.

Apple's new-repository onboarding and CI credentials cannot be copied by reading Said's GitHub secrets: GitHub secrets are write-only. Check the repository's current secrets/variables before configuring these items; the presence of workflow files does not prove that a release has run.

1. Open the project in Xcode 27, choose **Integrate → Create Workflow**, connect only `talhabalaj/pufflet`, and use the production macOS bundle ID. Create the app/product record if Apple requests it. Commit the generated Xcode Cloud manifest.
2. Create a clean, enabled, locked **Pufflet Release** workflow. Required macOS Test and Archive actions must use the **SteamLibrary** scheme. Use Xcode 27/macOS 27 SDK and a macOS 26 or 27 test destination. Add the Archive **Notarize** post-action. Keep Distribution Preparation at None, as for Said.
3. Enable **Manual Start → Tags** for `v` tags. Disable automatic branch/tag conditions so GitHub's API start does not duplicate the build. Start the integer build counter at 1 or higher and never decrease it.
4. Set `XCODE_CLOUD_WORKFLOW_ID` in GitHub repository variables. Add the existing or a dedicated App Store Connect API credential as `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY` (real p8 newlines). Apple manages the Developer ID signing certificate; no p12 export is needed.
5. Add a dedicated Cloudflare token as `CLOUDFLARE_API_TOKEN`. Account permissions for website deployment: Workers Scripts Write and Account Settings Read. Zone permissions for balaj.me only: Workers Routes Write and Zone Read. The already backed-up token also has account-wide R2 permission; release publishing no longer uses it. These account-level permissions cover other Workers; do not substitute the interactive OAuth session.
6. Keep `SPARKLE_PRIVATE_KEY` in GitHub Actions secrets and a recovery copy in 1Password. `SPARKLE_PUBLIC_KEY` and `CLOUDFLARE_ACCOUNT_ID` are public repository variables. Set `CLOUDFLARE_CI_ENABLED=true` after installing the Cloudflare CI token.

## Publish

Push a new unused numeric version tag, for example `v0.1.0`, pointing to the exact audited commit. `.github/workflows/release.yml` verifies the workflow/product/source identity and accepts only Apple's stapled notarized artifact. It validates Developer ID, Hardened Runtime, bundle ID, Apple silicon architecture, Sparkle key/feed, entitlements, stapled ticket and Gatekeeper assessment before packaging.

GitHub signs the ZIP and feed, creates a draft release for the exact source tag, and uploads the versioned archive, checksum, manifest and signed appcast without overwriting existing assets. Matching retries are allowed. After checking all draft assets it publishes with `--latest=false`, verifies anonymous downloads, rechecks against downgrades, then marks the release latest as the final promotion. The Worker keeps `/appcast.xml`, `/downloads/manifest.json`, and `/downloads/Pufflet-<version>-<build>.zip` stable while GitHub hosts the bytes. Publication is serialized. An interrupted publication can resume via workflow_dispatch using the original tag and completed `cloud_build_id`. Select `main` as the workflow ref to use repaired publishing tools without rebuilding the app: the Cloud job still pins the app to the input tag/commit, and the package check requires the embedded runtime pin to match the selected tooling checkout.

Only the publish job receives `contents: write` and GitHub's ephemeral `GH_TOKEN`; no additional stored token or bucket is required. Cloudflare credentials are used solely for deploying the website. Existing R2 configuration/secrets are retained for recovery but unused by the application release publisher.

## Separate runtime artifact

Normal app builds must not download or bundle Wine. Runtime maintainers explicitly run `Runtime/bootstrap-runtime.sh`, then `bash scripts/ci/package-runtime.sh prepare build/RuntimeSource/PuffletRuntime.app build/RuntimeArtifact`. This assembles only Wine, DXMT and supporting frameworks; signs every native component and the wrapper with Developer ID; and creates a ZIP for Apple notarization. Submit that ZIP with the backed-up Pufflet ASC credential, then run `bash scripts/ci/package-runtime.sh finalize build/RuntimeArtifact` only after acceptance. Finalization staples the ticket, checks Gatekeeper, creates the `COPYFILE_DISABLE=1` tar.xz without hard links/xattrs, and verifies the signed app again after fresh extraction.

The immutable runtime release tag is `runtime-wine-11.0-dxmt-1`, asset `PuffletRuntime-wine-11.0-dxmt-1.tar.xz`. Publish runtime releases with `--latest=false` so they never replace the app feed. The app ships the exact GitHub asset URL, final SHA-256, compressed/expanded byte bounds and Developer ID team in `Resources/RuntimeArtifact.json`. A runtime release must include corresponding Wine/DXMT source and licensing provenance. Forking a source repository does not preserve its release assets; the independently hosted, verified asset is the mirror. New runtime bytes require a new version and app pin, never replacement of an existing version.

Only describe notarization as complete after a successful Apple artifact and Gatekeeper/stapler checks. Only describe automatic installation as tested after an actual upgrade between two signed releases. Neither has been verified for Pufflet yet.
