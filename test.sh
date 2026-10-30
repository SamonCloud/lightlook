#!/bin/zsh
set -eu
cd -- "${0:A:h}"
mkdir -p build/module-cache
xcrun swiftc -O -swift-version 5 -module-cache-path "$PWD/build/module-cache" -framework AppKit -framework ImageIO -framework AVFoundation -framework Network -framework UniformTypeIdentifiers Sources/Media.swift Sources/Casting.swift Tests/main.swift -o build/media-tests
build/media-tests "$PWD/build/测试素材"
