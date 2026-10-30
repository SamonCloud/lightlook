#!/bin/zsh
set -eu
cd -- "${0:A:h}"
mkdir -p build/module-cache
xcrun swiftc -O -swift-version 5 -module-cache-path "$PWD/build/module-cache" -framework CryptoKit Sources/FileTags.swift Sources/FileBatch.swift Tests/FileActions/main.swift -o build/file-action-tests
build/file-action-tests "$PWD/build" "$@"
