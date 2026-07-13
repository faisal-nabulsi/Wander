#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# publish-ota.sh — ship a Wander OTA update.
#
# Bumps the build number, builds an unsigned IPA, stages it as the OTA payload
# on the website, and writes update.json (the manifest the app reads on launch).
# Everyone already running a build that contains WanderUpdater auto-updates on
# their next launch — no computer.
#
#   ./publish-ota.sh "PoGo Mode + auto-refresh"
#
# Then push BOTH repos (the script prints the exact commands).
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

NOTES="${1:-New update}"
PBX="Wander.xcodeproj/project.pbxproj"
SITE_DL="$HOME/Developer/wander-site/github-pages/downloads"

# 1) bump the build number (CURRENT_PROJECT_VERSION, both Debug+Release configs)
CUR=$(grep -oE "CURRENT_PROJECT_VERSION = [0-9]+" "$PBX" | head -1 | grep -oE "[0-9]+$")
BUILD=$((CUR + 1))
sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]*/CURRENT_PROJECT_VERSION = $BUILD/g" "$PBX"
VERSION=$(grep -oE "MARKETING_VERSION = [^;]+" "$PBX" | head -1 | sed 's/MARKETING_VERSION = //;s/;//')
echo "== Publishing build $BUILD (v$VERSION): $NOTES =="

# 2) build the unsigned IPA (same recipe as build_ipa.yml; device slice)
rm -rf build/Wander.xcarchive Wander.ipa Payload
xcodebuild clean archive -project Wander.xcodeproj -scheme "Wander" -configuration Debug \
  -archivePath build/Wander.xcarchive -sdk iphoneos -destination 'generic/platform=iOS' \
  ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  SWIFT_OPTIMIZATION_LEVEL="-Onone" IPHONEOS_DEPLOYMENT_TARGET=17.4 > /tmp/wander-ota-archive.log 2>&1
if [ ! -d "build/Wander.xcarchive/Products/Applications/Wander.app" ]; then
  echo "ARCHIVE FAILED — see /tmp/wander-ota-archive.log"; tail -6 /tmp/wander-ota-archive.log; exit 1
fi
mkdir -p Payload && cp -R "build/Wander.xcarchive/Products/Applications/Wander.app" Payload/
zip -qr Wander.ipa Payload && rm -rf Payload

# 3) stage the payload the manifest points at
cp Wander.ipa "$SITE_DL/Wander.ipa"

# 4) write the manifest (the app fetches this from raw.githubusercontent .../main/update.json)
cat > update.json <<JSON
{
  "build": $BUILD,
  "version": "$VERSION",
  "payloadURL": "https://wanderspoofer.com/downloads/Wander.ipa",
  "notes": "$NOTES"
}
JSON

echo
echo "== IPA + manifest ready (build $BUILD). Ship it by pushing BOTH repos: =="
echo "  cd ~/Developer/StikDebug-fork && git add update.json Wander.xcodeproj/project.pbxproj && git commit -m \"OTA build $BUILD: $NOTES\" && git push"
echo "  cd ~/Developer/wander-site/github-pages && git add downloads/Wander.ipa && git commit -m \"OTA payload build $BUILD\" && git push"
