# Template for the Homebrew cask. The release workflow fills the @…@ markers with scripts/release.py cask and attaches
# the result to the GitHub release as icloudy.rb; copy that file to Casks/icloudy.rb in the ruvelro/homebrew-tap
# repository (docs/DISTRIBUCION.md, «Homebrew»).
cask "icloudy" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/ruvelro/iCloudy/releases/download/v#{version}/@ZIP@"
  name "iCloudy"
  desc "Explorador de archivos para varias nubes a la vez"
  homepage "https://github.com/ruvelro/iCloudy"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "iCloudy.app"

  # The sandbox keeps everything in the container. The Keychain items are left alone: they hold the accounts, and
  # whoever zaps may reinstall.
  zap trash: [
    "~/Library/Application Scripts/dev.icloudy.desktop",
    "~/Library/Containers/dev.icloudy.desktop",
  ]
@CAVEATS@
end
