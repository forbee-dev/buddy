cask "buddy" do
  version "0.5.1"
  sha256 "492b6d1634e44be87188730c24cf0a18984b8315b813e7768907b1fb851eb64d"

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

  caveats <<~EOS
    Buddy is not notarized yet. On first open, go to System Settings → Privacy & Security → Open Anyway.
  EOS
end
