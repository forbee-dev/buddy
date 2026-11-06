cask "buddy" do
  version "1.1.0"
  sha256 "7f240eb9302b7a53d38fd4556b7b60ce9d7c5b797ccb80fa1cc9deccf64635c7"

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
