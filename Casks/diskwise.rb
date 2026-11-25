# Documentation: https://github.com/DreamOfXM/diskwise/blob/main/docs/homebrew.md
cask "diskwise" do
  version "2.4"
  sha256 "ca7ff95c8f10f4e363beda01f807482fae22f11f73b0658e0d9838663d5474ec"

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
