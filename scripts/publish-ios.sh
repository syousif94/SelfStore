#!/bin/zsh
# Archives the SelfStore iOS app ad hoc and uploads it to the SelfStore running on this Mac.
# Needs an Apple account in Xcode > Settings > Accounts (team 5E7D5R7C83).
set -euo pipefail
cd "${0:A:h}/.."
NOTES="${1:-}"
rm -rf build/SelfStoreiOS.xcarchive build/export
xcodebuild -project SelfStore.xcodeproj -scheme SelfStoreiOS -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/SelfStoreiOS.xcarchive \
  -allowProvisioningUpdates archive | grep -E "error:|ARCHIVE"
xcodebuild -exportArchive -archivePath build/SelfStoreiOS.xcarchive \
  -exportOptionsPlist scripts/ExportOptions.plist -exportPath build/export \
  -allowProvisioningUpdates | grep -E "error|EXPORT"
curl --fail-with-body --data-binary @build/export/SelfStore.ipa \
  "http://localhost:8765/api/apps?notes=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$NOTES")"
