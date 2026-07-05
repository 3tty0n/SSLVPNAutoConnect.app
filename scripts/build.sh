#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/VPNAutoConnect.xcodeproj"
SCHEME="VPNAutoConnect"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$ROOT/build" \
  build

APP="$ROOT/build/Build/Products/Release/SSLVPNAutoConnect.app"
echo ""
echo "Built: $APP"
