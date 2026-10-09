# Releasing Porchlight

No release of Porchlight has been made. This folder holds what a first release needs that could be
prepared without an Apple Developer account:

| File | What it is |
|---|---|
| [`../scripts/release.sh`](../scripts/release.sh) | Builds an unsigned disk image and its checksum. |
| [`homebrew/porchlight.rb`](homebrew/porchlight.rb) | A draft Homebrew cask. Not published anywhere. |

Everything below step 1 can only be done by the repository owner, and **none of it has been done**.
Each step is marked.

## 1. Build the image: scripted, works today

```sh
./scripts/release.sh 0.1.0
```

The version is `MAJOR.MINOR.PATCH`, optionally with a pre-release part (`0.1.0-rc.1`), and without
a leading `v`. The script:

1. runs `./scripts/make-app.sh 0.1.0`, which builds the release binaries with SwiftPM, assembles
   `dist/Porchlight.app` with that version in its `Info.plist`, and ad-hoc signs it;
2. checks that the bundle carries the version and passes `codesign --verify --deep --strict`;
3. makes `Porchlight-0.1.0.dmg` with `hdiutil`, holding `Porchlight.app` and a link to
   `/Applications`, and runs `hdiutil verify` on it;
4. writes `Porchlight-0.1.0.dmg.sha256` in `shasum -a 256` format.

Both files go to `dist/release`, or to the folder named by `PORCHLIGHT_RELEASE_OUT` (a relative
path is taken from the repository root). `dist/` is ignored by git. Check the pair with:

```sh
cd dist/release && shasum -a 256 -c Porchlight-0.1.0.dmg.sha256
```

Running it again replaces the image and checksum for that version. It never uploads, tags,
publishes, or signs with a real identity. If `PORCHLIGHT_SIGN_IDENTITY` or
`PORCHLIGHT_NOTARY_PROFILE` is set it stops with an error instead of producing an ad-hoc build that
could be mistaken for a signed one, because those steps are still commented out (steps 2 and 3).

What you get is good for trying the app on your own Mac. On anyone else's, Gatekeeper blocks it
until they choose "Open Anyway" in System Settings > Privacy & Security.

Two limits of the image as built today:

- **One architecture.** `swift build` builds for the machine it runs on, so an image built on Apple
  silicon holds an arm64 app only. The script prints the architecture. A universal build
  (`swift build --arch arm64 --arch x86_64`) needs Xcode, not just the Command Line Tools, and
  `make-app.sh` does not do it.
- **The version string is used as given** for both `CFBundleShortVersionString` and
  `CFBundleVersion`. Apple documents both as numbers separated by periods, so a pre-release part
  such as `-rc.1` is outside that. It is fine for a test image; decide the scheme before the first
  real release, and before Sparkle (step 5), which orders updates by `CFBundleVersion`.

## 2. Developer ID signing: NOT DONE, owner only

Needs membership of the Apple Developer Program and a "Developer ID Application" certificate in the
keychain of the machine that builds the release. `spec.md` §9 records that the development machine
has no signing identity.

- Enable the block marked `OWNER: Developer ID signing` in `scripts/release.sh`. It signs the
  command-line tool in `Contents/Helpers` first, then the bundle, both with the hardened runtime
  (`--options runtime`) and a secure timestamp, reading the identity from
  `PORCHLIGHT_SIGN_IDENTITY`. Remove `PORCHLIGHT_SIGN_IDENTITY` from the check near the top of the
  script that refuses it.
- The block refers to `packaging/Porchlight.entitlements`, which does not exist yet. Porchlight is
  not sandboxed (`spec.md` §12: it has to run `claude` and read `~/.claude`), so the file may need
  nothing beyond what step 4 adds. Create it then, or drop the `--entitlements` line.
- The commands in that block have never been run. Treat them as a starting point.

## 3. Notarisation: NOT DONE, owner only

Needs step 2, and notary credentials stored once with `xcrun notarytool store-credentials` (an
Apple ID, the team ID and an app-specific password, or an App Store Connect API key).

- Enable the block marked `OWNER: sign and notarise the image` in `scripts/release.sh`. It signs
  the image, submits it with `notarytool` using the keychain profile named by
  `PORCHLIGHT_NOTARY_PROFILE`, staples the ticket, and asks `spctl` for a verdict. It sits before
  the checksum on purpose: signing and stapling change the image. Remove
  `PORCHLIGHT_NOTARY_PROFILE` from the check near the top of the script.
- `notarytool` and `stapler` ship with Xcode, not with the Command Line Tools.
- These commands have never been run either.
- When this is done, remove the "not notarised" caveat from the cask and the note in the main
  README.

## 4. Time-sensitive notification entitlement: NOT DONE, owner only

The "Mark as time-sensitive after" setting only takes effect in a build that macOS allows to use
that notification level. An ad-hoc build is not allowed, and the Settings tab says so.

- The entitlement is `com.apple.developer.usernotifications.time-sensitive`. Turn on the
  Time Sensitive Notifications capability for the app ID `io.github.ksawerykarwacki.porchlight` in
  the developer account, add the key to `packaging/Porchlight.entitlements`, and sign with it in
  step 2.
- Entitlements under `com.apple.developer.` generally have to be backed by a provisioning profile
  embedded in the bundle (`Contents/embedded.provisionprofile`), and `make-app.sh` embeds none.
  Whether a Developer ID build needs one for this entitlement has not been tried. Check it first:
  a bundle that claims an entitlement its profile does not grant will not launch.
- Verify on a signed build that the Settings tab stops showing the "cannot send time-sensitive
  notifications" note.

## 5. Update signing keys, if Sparkle is adopted: NOT DONE, owner only

`spec.md` D10 proposes Sparkle for updates. It is not in the package today: there are no
dependencies, and nothing checks for updates. If it is adopted:

- generate the EdDSA key pair with Sparkle's `generate_keys`; the private key stays in the owner's
  keychain and is never committed;
- put the public key (`SUPublicEDKey`) and the feed address (`SUFeedURL`) in the `Info.plist` that
  `make-app.sh` writes;
- sign each image with `sign_update` and publish an appcast;
- embed and sign `Sparkle.framework` in the bundle, which `make-app.sh` does not do.

## 6. Create the GitHub release: NOT DONE, owner only

No tag and no release exist. The cask expects the tag `v<version>` and the asset name the script
produces:

```sh
git tag -s v0.1.0 -m "Porchlight 0.1.0"
git push origin v0.1.0
gh release create v0.1.0 --title "Porchlight 0.1.0" --notes-file <notes> \
    dist/release/Porchlight-0.1.0.dmg dist/release/Porchlight-0.1.0.dmg.sha256
```

Build from the tagged commit, so the image matches the source the tag names. Until step 3 is done,
say in the release notes that the build is not notarised.

## 7. Publish the cask to a tap: NOT DONE, owner only

- Create a tap repository (by Homebrew's convention `ksawerykarwacki/homebrew-tap`, giving
  `brew install --cask ksawerykarwacki/tap/porchlight`) and copy `homebrew/porchlight.rb` to
  `Casks/porchlight.rb` there.
- Set `version`, and set `sha256` to the first field of `Porchlight-<version>.dmg.sha256`. The
  draft carries a placeholder checksum.
- Check it with `brew audit --cask --new porchlight` and `brew style`, then install from the tap on
  a clean account. The draft has only been checked for Ruby syntax (`ruby -c`); it has never been
  audited or installed.
- The download address only works once the repository is public (step 8).
- Homebrew's own cask repository does not take apps that fail Gatekeeper, so an unnotarised build
  can only live in a personal tap.

## 8. Make the repository public: NOT DONE, owner only

The repository is private. Before changing that:

- read through the history and the open pull requests for anything that should not be public;
- look at the two Claude workflows in `.github/workflows/`: they use a repository secret, and on a
  public repository anyone can open a pull request or comment;
- the CI workflow (`.github/workflows/ci.yml`) needs no secrets and has a read-only token, so it is
  safe to run on pull requests from forks. macOS runner minutes are free for public repositories.
