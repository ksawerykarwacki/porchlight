# DRAFT. Not published to any tap, and the release it points at does not exist yet.
#
# Before publishing (packaging/README.md, step 7): set `version` to the released version and
# `sha256` to the first field of Porchlight-<version>.dmg.sha256, as written by
# scripts/release.sh. The checksum below is a placeholder, so installing from this file fails
# its checksum test, which is the right outcome for a draft.
cask "porchlight" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  # The asset name is the one scripts/release.sh produces; the tag is "v" followed by the version.
  url "https://github.com/ksawerykarwacki/porchlight/releases/download/v#{version}/Porchlight-#{version}.dmg"
  name "Porchlight"
  desc "Menu-bar companion for Claude Code background sessions"
  homepage "https://github.com/ksawerykarwacki/porchlight"

  # The app runs on macOS 14 or later. scripts/release.sh builds for the machine it runs on;
  # built on Apple silicon the image holds an arm64 app only. Drop the arch line if the release
  # becomes a universal build.
  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "Porchlight.app"
  # The command-line tool sits in Contents/Helpers, not next to the app's own binary: the default
  # file system ignores case, so "porchlight" and "Porchlight" cannot share a folder.
  binary "#{appdir}/Porchlight.app/Contents/Helpers/porchlight"

  zap trash: "~/Library/Application Support/Porchlight"

  caveats <<~EOS
    This build of Porchlight is not notarised by Apple and is not signed with a Developer ID.
    macOS will refuse to open it the first time. To allow it, open
    System Settings > Privacy & Security and choose "Open Anyway" for Porchlight.

    Time-sensitive reminders need a signed release and are not available in this build.

    Porchlight needs the Claude Code CLI (`claude`), which it does not install.
  EOS
end
