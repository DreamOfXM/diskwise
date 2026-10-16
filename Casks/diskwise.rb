cask "diskwise" do
  version "1.8"
  sha256 "43d50b1ab08c1a9433510502bbac71183c90706ee41013cb8d2753bb377f84e8"

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
