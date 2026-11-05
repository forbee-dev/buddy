cask "buddy" do
  version "1.0.0"
  sha256 "12ad063bb9acb8c5a198ae42ce0f0e0aeac18bce5d8550208ed3de2f3df652ff"

  url "https://github.com/forbee-dev/buddy/releases/download/v#{version}/Buddy-#{version}.dmg"
  name "Buddy"
  desc "Pixel mascot for every Claude Code session"
  homepage "https://github.com/forbee-dev/buddy"

  depends_on macos: :sonoma

  app "Buddy.app"

  zap trash: [
    "~/Library/Application Support/Buddy",
    "~/Library/Preferences/com.tiagosantos.buddy.plist",
  ]

  livecheck do
    url :url
    strategy :github_latest
  end

  caveats <<~EOS
    The DMG is signed with a self-signed certificate and is not notarized.
    On first open, go to System Settings → Privacy & Security → Open Anyway.
  EOS
end
