#!/bin/bash
# Rebuilds AppIcon.icns from AppIcon.svg.
set -euo pipefail
cd "$(dirname "$0")"
T="$(mktemp -d)"
swiftc -swift-version 5 -o "$T/render-icon" render-icon.swift
"$T/render-icon" AppIcon.svg "$T/AppIcon.iconset"
iconutil -c icns "$T/AppIcon.iconset" -o AppIcon.icns
rm -rf "$T"
echo "Built $PWD/AppIcon.icns"
