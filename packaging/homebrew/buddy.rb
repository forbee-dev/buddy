cask "buddy" do
  version "0.3.0"
  sha256 "f8fe9740a33d633e48e05ecae62e89119c34b79fc58a58118a492c4f27e79760"

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
