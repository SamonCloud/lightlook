#!/bin/zsh
set -eu
cd -- "${0:A:h}"
mkdir -p build/module-cache
xcrun swiftc -O -swift-version 5 -module-cache-path "$PWD/build/module-cache" -framework MapKit -framework CoreLocation Sources/Location.swift Tests/Location/main.swift -o build/location-tests
build/location-tests "$@"
