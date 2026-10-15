# Pufflet builds and releases

This is the same release architecture as Said: Xcode Cloud creates a **STAPLED_NOTARIZED_ARCHIVE**, GitHub verifies it on macOS, Sparkle signs the archive/feed, and private R2 stores immutable downloads served through `https://pufflet.apps.balaj.me`.

## Configured

- Public source repository: `talhabalaj/pufflet`.
- Shared Xcode project/scheme: `SteamLibrary.xcodeproj` / `SteamLibrary`.
- Developer team: `W7TT249CUU`; production identity `me.balaj.SteamLibrary`.
- Worker `pufflet-site`, custom domain `pufflet.apps.balaj.me`, private bucket `pufflet-releases`.
- Sparkle public verification key is committed in the app's typed Info.plist settings. The private key is held in Keychain and backed up in 1Password; CI uses an encrypted repository secret. No key belongs in source control.
- CI runs release-tooling tests, website types/build and script checks. Native tests run locally and in the Xcode Cloud release workflow.

## Activation

Apple's new-repository onboarding and CI credentials cannot be copied by reading Said's GitHub secrets: GitHub secrets are write-only. Check the repository's current secrets/variables before configuring these items; the presence of workflow files does not prove that a release has run.

1. Open the project in Xcode 27, choose **Integrate → Create Workflow**, connect only `talhabalaj/pufflet`, and use the production macOS bundle ID. Create the app/product record if Apple requests it. Commit the generated Xcode Cloud manifest.
2. Create a clean, enabled, locked **Pufflet Release** workflow. Required macOS Test and Archive actions must use the **SteamLibrary** scheme. Use Xcode 27/macOS 27 SDK and a macOS 26 or 27 test destination. Add the Archive **Notarize** post-action. Keep Distribution Preparation at None, as for Said.
3. Enable **Manual Start → Tags** for `v` tags. Disable automatic branch/tag conditions so GitHub's API start does not duplicate the build. Start the integer build counter at 1 or higher and never decrease it.
4. Set `XCODE_CLOUD_WORKFLOW_ID` in GitHub repository variables. Add the existing or a dedicated App Store Connect API credential as `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY` (real p8 newlines). Apple manages the Developer ID signing certificate; no p12 export is needed.
5. Add a dedicated Cloudflare token as `CLOUDFLARE_API_TOKEN`. Account permissions: Workers Scripts Write, Workers R2 Storage Write and Account Settings Read. Zone permissions for balaj.me only: Workers Routes Write and Zone Read. These account-level permissions cover other Workers and buckets; do not substitute the interactive OAuth session.
6. Keep `SPARKLE_PRIVATE_KEY` in GitHub Actions secrets and a recovery copy in 1Password. `SPARKLE_PUBLIC_KEY`, `CLOUDFLARE_ACCOUNT_ID`, and `R2_RELEASE_BUCKET` are public repository variables. Set `CLOUDFLARE_CI_ENABLED=true` after installing the Cloudflare CI token.

## Publish

Push a new unused numeric version tag, for example `v0.1.0`, pointing to the exact audited commit. `.github/workflows/release.yml` verifies the workflow/product/source identity and accepts only Apple's stapled notarized artifact. It validates Developer ID, Hardened Runtime, bundle ID, Apple silicon architecture, Sparkle key/feed, entitlements, stapled ticket and Gatekeeper assessment before packaging.

GitHub signs the ZIP and feed, uploads the immutable versioned archive and checksum, verifies public size/hash, promotes the manifest, then uploads the signed feed last. First publication permits a missing manifest; later publication refuses downgrade or replacement of an immutable build. Publication is serialized. An interrupted publication can resume via workflow_dispatch using the original tag and completed `cloud_build_id`.

The Cloudflare object API has a 300 MB request limit; a release exceeding that limit needs an S3 multipart uploader before publication. No oversized release is silently truncated.

Only describe notarization as complete after a successful Apple artifact and Gatekeeper/stapler checks. Only describe automatic installation as tested after an actual upgrade between two signed releases. Neither has been verified for Pufflet yet.
