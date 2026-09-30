#!/bin/sh
# Builds Release and installs to /Applications. Touching the bundle makes macOS drop its cached icon.
set -e
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null
xcodebuild -project Docxer.xcodeproj -scheme Docxer -configuration Release -derivedDataPath build/dd build | grep -E "error:|BUILD"
rm -rf /Applications/Docxer.app
ditto build/dd/Build/Products/Release/Docxer.app /Applications/Docxer.app
touch /Applications/Docxer.app /Applications/Docxer.app/Contents/Info.plist
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R /Applications/Docxer.app
echo "Installed /Applications/Docxer.app"
