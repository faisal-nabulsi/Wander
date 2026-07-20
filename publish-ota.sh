#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# publish-ota.sh — ship a Wander OTA update.
#
# Bumps the build number, builds an unsigned IPA, uploads it as the OTA payload
# to the GitHub release (faisal-nabulsi/Wander), and writes update.json (the
# manifest the app reads on launch). Everyone already running a build that
# contains WanderUpdater auto-updates on their next launch — no computer.
#
#   ./publish-ota.sh "PoGo Mode + auto-refresh"
#
# Then push THIS repo (the script prints the exact command). Payloads no longer
# live in the wander-site repo — committing binaries there bloated its git
# history past 4GB (migrated to Releases 2026-07-20).
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

NOTES="${1:-New update}"
PBX="Wander.xcodeproj/project.pbxproj"
PAYLOAD_URL="https://github.com/faisal-nabulsi/Wander/releases/latest/download/Wander.ipa"

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

# 3) publish the payload: replace the Wander.ipa asset on the GitHub release. This is
#    the ONLY place the payload lives (update.json, apps.json and wander-installer's
#    sideload.rs all read releases/latest/download/Wander.ipa), so the upload must
#    succeed BEFORE the manifests advertise a build nobody can download — set -e
#    aborts the publish if gh fails.
LATEST_TAG=$(gh release list --repo faisal-nabulsi/Wander --limit 1 --json tagName --jq '.[0].tagName')
[ -n "$LATEST_TAG" ] || { echo "FATAL: no release exists on faisal-nabulsi/Wander"; exit 1; }
gh release upload "$LATEST_TAG" Wander.ipa --repo faisal-nabulsi/Wander --clobber
echo "GitHub release ($LATEST_TAG) Wander.ipa updated to build $BUILD."

# 4) write the manifest (the app fetches this from raw.githubusercontent .../main/update.json).
#    Written via json.dump — NOT a heredoc — so notes containing double-quotes, newlines or unicode
#    can never produce invalid JSON. A malformed update.json makes the app's strict JSON decode
#    throw and the OTA check silently no-ops for EVERYONE (this bit build 92: notes had quotes).
BUILD="$BUILD" VERSION="$VERSION" NOTES="$NOTES" PAYLOAD_URL="$PAYLOAD_URL" python3 - <<'PY'
import json, os
d = {
    "build": int(os.environ["BUILD"]),
    "version": os.environ["VERSION"],
    "payloadURL": os.environ["PAYLOAD_URL"],
    "notes": os.environ["NOTES"],
}
with open("update.json", "w") as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(f"update.json -> build {d['build']}")
PY

# 4b) Keep the SideStore source apps.json in LOCKSTEP. SideStore installs/refreshes whatever
#     apps.json declares; if it drifts from update.json (as it did — stale July build), new
#     sideloads get an outdated app. Bump build/size/date/notes + point at the same payload.
SIZE=$(stat -f%z Wander.ipa)
TODAY=$(date +%Y-%m-%d)
BUILD="$BUILD" VERSION="$VERSION" NOTES="$NOTES" SIZE="$SIZE" TODAY="$TODAY" python3 - <<'PY'
import json, os
p = "apps.json"
d = json.load(open(p))
build = os.environ["BUILD"]; version = os.environ["VERSION"]; notes = os.environ["NOTES"]
size = int(os.environ["SIZE"]); today = os.environ["TODAY"]
url = "https://wanderspoofer.com/downloads/Wander.ipa"
app = d["apps"][0]
minos = (app.get("versions") or [{}])[0].get("minOSVersion", "17.0")
app["version"] = version; app["buildVersion"] = build; app["versionDate"] = today
app["versionDescription"] = notes; app["downloadURL"] = url; app["size"] = size
app["versions"] = [{"version": version, "buildVersion": build, "date": today,
                    "localizedDescription": notes, "downloadURL": url, "size": size,
                    "minOSVersion": minos}]
json.dump(d, open(p, "w"), indent=2, ensure_ascii=False)
open(p, "a").write("\n")
print(f"apps.json -> build {build}, {size} bytes, {today}")
PY

# 4c) Update the GitHub RELEASE asset. The Wander Installer sideloads Wander from
#     github.com/faisal-nabulsi/Wander/releases/latest/download/Wander.ipa (see wander-installer
#     sideload.rs) — a new build that doesn't update the release makes the installer sideload a
#     STALE app, even though update.json + apps.json are current.
if command -v gh >/dev/null 2>&1; then
  LATEST_TAG=$(gh release list --repo faisal-nabulsi/Wander --limit 1 --json tagName --jq '.[0].tagName' 2>/dev/null)
  if [ -n "$LATEST_TAG" ] && gh release upload "$LATEST_TAG" Wander.ipa --repo faisal-nabulsi/Wander --clobber >/dev/null 2>&1; then
    echo "GitHub release ($LATEST_TAG) Wander.ipa updated to build $BUILD."
  else
    echo "WARN: could not update the GitHub release asset. Run manually so the installer isn't stale:"
    echo "  gh release upload $LATEST_TAG Wander.ipa --repo faisal-nabulsi/Wander --clobber"
  fi
else
  echo "WARN: gh not installed — update the GitHub release Wander.ipa manually or the installer stays stale."
fi

# 4b) Auto-announce the release in the Discord #updates channel. The webhook URL lives in a
#     gitignored local file (.updates-webhook) so the secret never enters git.
if [ -f .updates-webhook ]; then
  python3 - "$(cat .updates-webhook)" "$VERSION" "$BUILD" "$NOTES" <<'PY'
import sys, json, urllib.request
url, version, build, notes = sys.argv[1:5]
body = {
    "username": "Wander",
    "avatar_url": "https://wanderspoofer.com/favicon-192.png",
    "embeds": [{
        "title": f"\U0001F680 Wander v{version} (build {build}) is out",
        "description": notes[:3800] + "\n\n_Open Wander with the tunnel connected and it updates itself over the air — no computer._",
        "color": 1597349,  # brand #185FA5
        "footer": {"text": "Wander • auto-update", "icon_url": "https://wanderspoofer.com/favicon-192.png"},
    }],
}
try:
    # A real User-Agent is required — Discord's webhook endpoint sits behind Cloudflare, which
    # blocks urllib's default UA with a 1010 (looks like a 403).
    req = urllib.request.Request(url, data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "User-Agent": "Wander-OTA/1.0 (+https://wanderspoofer.com)"})
    urllib.request.urlopen(req, timeout=15)
    print("== Announced build in Discord #updates ==")
except Exception as e:
    print(f"WARN: couldn't post to #updates ({e})")
PY
fi

echo
echo "== Payload uploaded + manifests written (build $BUILD). Ship it by pushing this repo: =="
echo "  cd ~/Developer/wander-ios && git add update.json apps.json Wander.xcodeproj/project.pbxproj && git commit -m \"OTA build $BUILD: $NOTES\" && git push"
