#!/bin/zsh
set -eu
cd -- "${0:A:h}"
mkdir -p build/module-cache
xcrun swiftc -O -swift-version 5 -module-cache-path "$PWD/build/module-cache" -framework AppKit Sources/GridNavigation.swift Sources/CollectionViewport.swift Tests/GridNavigation/main.swift -o build/navigation-tests
build/navigation-tests
