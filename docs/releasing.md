# Releasing GitStride

This guide covers local distribution through [gitstride.zwyyy456.tech](https://gitstride.zwyyy456.tech) and [zwyyy456/GitStride Releases](https://github.com/zwyyy456/GitStride/releases). It does not deploy the website or Automation Worker.

## Distribution targets and desktop OAuth

`GitStride` is the Developer ID / GitHub Release target. `GitStrideAppStore` shares the app sources, enables App Sandbox with outgoing network access, and excludes the CLI runner and Sparkle. Use its shared scheme to archive for App Store Connect; the DMG and appcast scripts remain specific to the Release target. Update version and build numbers on both targets when shipping both distributions.

Both targets use the public `GITBOARD_OAUTH_CLIENT_ID` build setting. Register a desktop OAuth App separately from the Worker OAuth App and enable Device Flow. Never embed a Client Secret or reuse Worker access/refresh tokens. Signed Keychain access and container behavior must be checked with the actual distribution signing setup; unsigned builds do not validate these permissions.

## Version and update feed

Set **Version** (`MARKETING_VERSION`) and **Build** (`CURRENT_PROJECT_VERSION`) on the GitStride target in Xcode, for both Debug and Release. The app's Info.plist expands these settings. Each published update needs a higher build number; use a new public version for each release so its DMG and GitHub tag are unique.

`create_dmg.sh` reads the version from the exported app. `update_appcast.sh` uses Sparkle to extract the version, build number, minimum macOS version, archive length, and signature from the actual DMG. It checks that the DMG filename agrees with the packaged version.

`appcast.xml` is Sparkle's update catalog. The application reads it from this repository's `main` branch and downloads the referenced packages from GitHub Releases. An empty feed advertises no updates. It should contain only entries for packages that are available to users.

## One-time signing setup

1. In Xcode → Settings → Accounts, select your Apple developer account and team. The checked-in GitStride team is `G38CM6VNCC`.
2. Under Manage Certificates, create or import a **Developer ID Application** certificate and its private key. An Apple Development or Mac App Store distribution certificate serves a different distribution method. The release export uses Developer ID and inherits the team from the archive.
3. Obtain the Sparkle distribution matching `Package.resolved` from [Sparkle Releases](https://github.com/sparkle-project/Sparkle/releases). In the extracted distribution, run:

   ```bash
   ./bin/generate_keys --account gitstride
   ```

   This creates or reuses a signing key in your login Keychain and prints its **public** key. Put that public key in `GitStride/Info.plist` under `SUPublicEDKey`. Keep the private key in Keychain and back it up securely outside the repository. The release build checks the bundled public key against this account. The checked-in public key must be verified or replaced before the first release from your own signing account; do not assume an inherited key belongs to you.

4. Store your notarization credentials using `xcrun notarytool store-credentials gitstride-notary` and follow its interactive prompts. Apple documents the accepted account/API-key credentials in its [notarization guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

Sparkle's key signs update archives. Apple's Developer ID certificate signs the app. Both are used in this release process; neither private key belongs in Git.

## Build and package

Run the relevant build and behavior checks from [the command index](../docs-index.md) before preparing the release. Then:

```bash
./build_release.sh
./create_dmg.sh
```

The build script archives the Release configuration and exports it through Xcode's Developer ID distribution method. Xcode signs embedded components, including Sparkle. The exported app is copied to `GitStride.app`; archives, export logs, and dSYMs remain under `build/release/`.

The scripts use the version, bundle ID, and team from the project. No author certificate name or second version number is hardcoded in the scripts. `create_dmg.sh` packages an already exported app rather than implicitly rebuilding it.

## Notarize, then sign the update archive

Replace `VERSION` below with the version printed by the packaging script:

```bash
xcrun notarytool submit GitStride-VERSION.dmg \
  --keychain-profile gitstride-notary --wait
xcrun stapler staple GitStride-VERSION.dmg
xcrun stapler validate GitStride-VERSION.dmg
```

Proceed only after notarization reports **Accepted**. If it fails, inspect the notarization log and fix the reported signing/package issue before submitting again.

Prepare a small HTML release-notes file outside the repository's source directories, such as `build/release-notes.html`, then run:

```bash
./update_appcast.sh GitStride-VERSION.dmg build/release-notes.html
```

The notes argument is optional. The script validates the stapled ticket and uses the Sparkle tools resolved by the release build. It signs with the `gitstride` Keychain account, embeds the notes, and updates the repository's feed. Delta generation is disabled, so only the DMG needs uploading. It preserves existing feed entries and does not invent an extra build number.

Generate the feed **after** stapling: changes to the DMG bytes after signing invalidate Sparkle's archive signature.

## Publish

1. Create a GitHub Release tagged `vVERSION` from the intended source commit and attach the final notarized DMG. Use the same public version that appears in the app and DMG filename.
2. Verify the release asset is downloadable, then commit and publish the generated `appcast.xml` to `main`.
3. Update the download link on `gitstride.zwyyy456.tech` to the release. Website/DNS changes are separate from these scripts.
4. Verify installation and an older-to-newer Sparkle update on a separate test Mac or test account, including every CPU architecture advertised for the release. Use screenshots supplied from the running app when visual review is needed.

The scripts do not create releases, push commits, upload files, or modify DNS. Keep the archive and dSYMs so crash reports from the distributed build can be symbolicated.

## References

- [Sparkle distribution and appcast generation](https://sparkle-project.org/documentation/)
- [Publishing Sparkle updates](https://sparkle-project.org/documentation/publishing/)
- [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
