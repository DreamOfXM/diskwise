cask "diskwise" do
  version "1.9"
  sha256 "49320c1169bde8333399fdb45c817a8fadba112a5e43b88b4f0091461dbb4c08"

  url "https://github.com/DreamOfXM/diskwise/releases/download/v#{version}/DiskWise-#{version}-universal.dmg"
  name "DiskWise"
  desc "Open-source disk cleaner that only ever moves files to the Trash"
  homepage "https://github.com/DreamOfXM/diskwise"

  livecheck do
    url "https://github.com/DreamOfXM/diskwise/releases"
    strategy :github_latest
  end

  # From v1.3 the published DMG is a universal binary (arm64 + x86_64), so there is
  # no architecture to pin here.
  depends_on macos: :ventura

  app "DiskWise.app"

  uninstall quit: "com.dreamofxm.diskcleaner"

  zap trash: [
    "~/Library/Caches/com.dreamofxm.diskcleaner",
    "~/Library/Preferences/com.dreamofxm.diskcleaner.plist",
    "~/Library/Saved Application State/com.dreamofxm.diskcleaner.savedState",
  ]
end
