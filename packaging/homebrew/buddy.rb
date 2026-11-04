cask "buddy" do
  version "0.4.0"
  sha256 "6fd064c5fdbd4f1d3dc323e6d27cbe9e51f8bf6d1fd2fbdd0afb016a42ef1e84"

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
    Buddy is not notarized yet. On first open, go to System Settings → Privacy & Security → Open Anyway.
  EOS
end
