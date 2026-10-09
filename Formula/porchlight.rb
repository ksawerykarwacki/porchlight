# frozen_string_literal: true

# Builds Porchlight from source on the user's machine.
#
# That is what lets it be installed without an Apple Developer ID: macOS only checks
# notarisation on files that were downloaded (they carry a quarantine mark), and nothing here is
# downloaded as a binary. The bundle gets an ad-hoc signature, which Apple Silicon requires and
# which is enough for a locally built app.
#
# Keep this in step with scripts/make-app.sh, which does the bundling.
class Porchlight < Formula
  desc "Menu-bar companion for Claude Code background sessions"
  homepage "https://github.com/ksawerykarwacki/porchlight"
  license "Apache-2.0"
  head "https://github.com/ksawerykarwacki/porchlight.git", branch: "main"

  depends_on macos: :sonoma

  def install
    # Homebrew sandboxes the build; SwiftPM's own sandbox cannot run inside it.
    ENV["PORCHLIGHT_SWIFT_FLAGS"] = "--disable-sandbox"
    system "./scripts/make-app.sh", version.to_s
    prefix.install "dist/Porchlight.app"
    bin.install_symlink prefix/"Porchlight.app/Contents/Helpers/porchlight"
  end

  service do
    # The binary inside the bundle, so that its Info.plist (no Dock icon, bundle id) applies.
    run opt_prefix/"Porchlight.app/Contents/MacOS/Porchlight"
    process_type :interactive
  end

  def caveats
    <<~EOS
      Start Porchlight now and at every login:
        brew services start #{full_name}

      It needs Claude Code (the `claude` command) and shows a set-up card on first run.
      Install it one way only: a copy built with scripts/make-app.sh would run alongside this one.
    EOS
  end

  test do
    app = prefix/"Porchlight.app"
    system "codesign", "--verify", "--strict", app
    assert_equal "io.github.ksawerykarwacki.porchlight",
                 shell_output("plutil -extract CFBundleIdentifier raw #{app}/Contents/Info.plist").chomp
    assert_match "porchlight status", shell_output("#{bin}/porchlight help")
  end
end
