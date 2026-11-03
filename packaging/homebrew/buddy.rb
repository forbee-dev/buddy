cask "buddy" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/forbee-dev/buddy/releases/download/v#{version}/Buddy-#{version}.dmg"
  name "Buddy"
  desc "Pixel mascot for every Claude Code session"
  homepage "https://github.com/forbee-dev/buddy"

  depends_on macos: ">= :sonoma"

  app "Buddy.app"

  zap trash: [
    "~/Library/Application Support/Buddy",
    "~/Library/Preferences/com.tiagosantos.buddy.plist",
  ]

  caveats <<~EOS
    Buddy is not notarized. If macOS blocks it, run:
      xattr -dr com.apple.quarantine /Applications/Buddy.app
    Or open System Settings > Privacy & Security and click "Open Anyway".
  EOS
end
