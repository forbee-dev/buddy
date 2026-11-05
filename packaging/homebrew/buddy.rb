cask "buddy" do
  version "0.5.0"
  sha256 "f3550c89b3e811379dce2542ba7d4a5d27cece45fdb71cacf72e7a98cb333205"

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
