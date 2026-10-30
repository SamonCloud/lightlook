#!/bin/zsh
set -eu
cd -- "${0:A:h}"
mkdir -p build/module-cache
sources=(Sources/*.swift)
sources=(${sources:#Sources/main.swift})
xcrun swiftc -O -swift-version 5 -module-cache-path "$PWD/build/module-cache" -framework AppKit -framework ImageIO -framework AVKit -framework AVFoundation -framework Network -framework UniformTypeIdentifiers -framework MapKit -framework CoreLocation -framework CryptoKit "${sources[@]}" Tests/TagsUI/main.swift -o build/tag-ui-tests
build/tag-ui-tests "$PWD/build"
