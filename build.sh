#!/bin/zsh
set -eu
cd -- "${0:A:h}"
app_dir="${LIGHTLOOK_APP_DIR:-$PWD/build/轻览.app}"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" build/module-cache
xcrun swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx13.0" -module-cache-path "$PWD/build/module-cache" -framework AppKit -framework ImageIO -framework AVKit -framework AVFoundation -framework Network -framework UniformTypeIdentifiers -framework MapKit -framework CoreLocation -framework CryptoKit Sources/*.swift -o "$app_dir/Contents/MacOS/LightLook"
xcrun swiftc -O -module-cache-path "$PWD/build/module-cache" Tools/Icon.swift -o build/make-icon
build/make-icon "$PWD/build/AppIcon.iconset"
/usr/bin/iconutil -c icns build/AppIcon.iconset -o "$app_dir/Contents/Resources/LightLookIcon.icns"
/bin/rm -f "$app_dir/Contents/Resources/AppIcon.icns"
cp build/AppIcon.iconset/icon_512x512@2x.png "$app_dir/Contents/Resources/LightLookLogo.png"
cp Info.plist "$app_dir/Contents/Info.plist"
/usr/bin/plutil -lint "$app_dir/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$app_dir"
/usr/bin/codesign --verify --strict "$app_dir"
print "已构建：$app_dir"
