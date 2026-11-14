#!/bin/sh
# Rebuilds the native wrapper binary inside the installed app bundle.
set -e
cd "$(dirname "$0")"
APP="/Applications/Word Processor.app"
swiftc -O main.swift -o "$APP/Contents/MacOS/WordProcessor"
codesign --force --sign - "$APP" 2>/dev/null || true
echo "Built $APP/Contents/MacOS/WordProcessor"
