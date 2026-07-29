#!/bin/zsh
#
# wander-cert-deploy.sh — one-command build → sign → install for the CERT-SIGNED
# (entitlement-carrying) Wander build. Replaces the manual iOS App Signer step.
#
# WHY THIS EXISTS
#   Wander's normal OTA self-updater re-signs on-device with the user's Apple ID via
#   AltSign — which only maps 3 capabilities and SILENTLY STRIPS NetworkExtension and
#   HealthKit. So the entitlement build (own VPN tunnel + Adventure Sync) can never
#   ride the normal OTA. It must be signed with a cert whose PROFILE already carries
#   those entitlements. That signing needs the private key, so it happens here on the
#   Mac, then installs over USB via devicectl.
#
# THE RECIPE (reverse-engineered from the iOS App Signer output that actually worked):
#   • main app  : CFBundleIdentifier = <profile's app id>, embedded.mobileprovision PRESENT
#   • appex     : CFBundleIdentifier = <app id>.TunnelProv, embedded profile ABSENT,
#                 signed with entitlements whose application-identifier is the PARENT's
#   • entitlements come from the PROFILE wholesale (that's how healthkit +
#     networkextension reach the signature without living in Wander.entitlements)
#   • codesign inside-out: frameworks → appex → app
#
# USAGE
#   ./tools/wander-cert-deploy.sh                # build (HealthKit ON) + sign + install
#   ./tools/wander-cert-deploy.sh --no-build     # sign+install the last build (fast)
#   ./tools/wander-cert-deploy.sh --no-healthkit # build WITHOUT the HealthKit flag
#   ./tools/wander-cert-deploy.sh --sign-only    # produce the signed IPA, don't install
#
set -e
setopt NULL_GLOB            # zsh: unmatched globs expand to nothing instead of erroring
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CERT_DIR="${WANDER_CERT_DIR:-/Users/faisalnabulsi/Desktop/wander}"
PROFILE="${WANDER_PROFILE:-$CERT_DIR/Development.mobileprovision}"
OUT_IPA="${WANDER_OUT_IPA:-$CERT_DIR/Wander-signed.ipa}"
ARCHIVE="$REPO/build/Wander-cert.xcarchive"

DO_BUILD=1; HEALTHKIT=1; INSTALL=1
for a in "$@"; do
  case "$a" in
    --no-build) DO_BUILD=0 ;;
    --no-healthkit) HEALTHKIT=0 ;;
    --sign-only) INSTALL=0 ;;
  esac
done

log() { print -r -- "▸ $*"; }
die() { print -r -- "✗ $*" >&2; exit 1; }

[ -f "$PROFILE" ] || die "profile not found: $PROFILE"

# ── 1. Read identity + app id + team out of the PROFILE (so swapping certs Just Works)
log "reading provisioning profile…"
PROF_XML=$(mktemp).plist
security cms -D -i "$PROFILE" > "$PROF_XML" 2>/dev/null || die "could not decode profile"

read -r TEAM APPID_FULL PROF_NAME EXPIRY <<< "$(python3 - "$PROF_XML" <<'PY'
import plistlib, sys
d = plistlib.load(open(sys.argv[1],'rb'))
e = d.get('Entitlements', {})
full = e.get('application-identifier','')
team = e.get('com.apple.developer.team-identifier','')
print(team, full, (d.get('Name','?') or '?').replace(' ','_'), d.get('ExpirationDate'))
PY
)"
BUNDLE_ID="${APPID_FULL#${TEAM}.}"     # strip "TEAM." → the real bundle id
[ -n "$BUNDLE_ID" ] || die "could not derive bundle id from profile"
log "  team=$TEAM  bundle=$BUNDLE_ID  expires=$EXPIRY"

# Find a codesigning identity in the keychain whose OU matches the profile's team.
IDENTITY=""
while read -r _n sha rest; do
  [ -n "$sha" ] || continue
  if security find-certificate -a -Z 2>/dev/null | grep -q "$sha" ; then :; fi
  ou=$(security find-certificate -c "${rest//\"/}" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null)
  case "$ou" in *"OU=$TEAM"*) IDENTITY="$sha"; break ;; esac
done < <(security find-identity -v -p codesigning 2>/dev/null | sed 's/^ *//')
[ -n "$IDENTITY" ] || IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk 'NR==1{print $2}')
[ -n "$IDENTITY" ] || die "no codesigning identity in keychain — import the .p12 once (double-click it)"
log "  signing identity: $IDENTITY"

# ── 2. Build (unsigned), optionally with the HealthKit compile flag
if [ "$DO_BUILD" = 1 ]; then
  COND="DEBUG"; [ "$HEALTHKIT" = 1 ] && COND="DEBUG WANDER_HEALTHKIT"
  log "building (SWIFT_ACTIVE_COMPILATION_CONDITIONS=\"$COND\")… this takes a few minutes"
  rm -rf "$ARCHIVE"
  ( cd "$REPO" && xcodebuild clean archive -project Wander.xcodeproj -scheme "Wander" \
      -configuration Debug -archivePath "$ARCHIVE" -sdk iphoneos \
      -destination 'generic/platform=iOS' ONLY_ACTIVE_ARCH=NO \
      CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
      SWIFT_OPTIMIZATION_LEVEL="-Onone" IPHONEOS_DEPLOYMENT_TARGET=17.4 \
      SWIFT_ACTIVE_COMPILATION_CONDITIONS="$COND" ) > /tmp/wander-cert-build.log 2>&1 \
    || { tail -25 /tmp/wander-cert-build.log; die "archive failed (see /tmp/wander-cert-build.log)"; }
fi
SRC_APP="$ARCHIVE/Products/Applications/Wander.app"
[ -d "$SRC_APP" ] || die "no built app at $SRC_APP (run without --no-build first)"

# ── 3. Stage + rewrite bundle ids
STAGE=$(mktemp -d)/Payload
mkdir -p "$STAGE"
cp -R "$SRC_APP" "$STAGE/"
APP="$STAGE/Wander.app"
log "staging + setting bundle ids…"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Info.plist"
for ax in "$APP"/PlugIns/*.appex; do
  [ -d "$ax" ] || continue
  sfx="${ax:t:r}"                                   # e.g. TunnelProv
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID.$sfx" "$ax/Info.plist"
  rm -f "$ax/embedded.mobileprovision"              # appex carries NO profile (matches working build)
  log "  appex $sfx → $BUNDLE_ID.$sfx"
done

# ── 4. Embed profile (main app only) + extract its entitlements
cp "$PROFILE" "$APP/embedded.mobileprovision"
ENT=$(mktemp).plist
python3 - "$PROF_XML" "$ENT" <<'PY'
import plistlib, sys
d = plistlib.load(open(sys.argv[1],'rb'))
plistlib.dump(d.get('Entitlements', {}), open(sys.argv[2],'wb'))
PY
log "entitlements from profile: $(grep -c '<key>' "$ENT") keys (healthkit: $(grep -qc healthkit "$ENT" >/dev/null && echo yes || echo no))"

# ── 5. Codesign INSIDE-OUT: frameworks → appex → app
log "signing…"
for fw in "$APP"/Frameworks/*.framework "$APP"/Frameworks/*.dylib; do
  [ -e "$fw" ] || continue
  codesign -f -s "$IDENTITY" --timestamp=none "$fw" >/dev/null 2>&1 || die "sign failed: ${fw:t}"
done
for ax in "$APP"/PlugIns/*.appex; do
  [ -d "$ax" ] || continue
  codesign -f -s "$IDENTITY" --entitlements "$ENT" --timestamp=none "$ax" >/dev/null 2>&1 \
    || die "sign failed: ${ax:t}"
done
codesign -f -s "$IDENTITY" --entitlements "$ENT" --timestamp=none "$APP" >/dev/null 2>&1 \
  || die "sign failed: Wander.app"
codesign --verify --deep --strict "$APP" 2>/dev/null || log "  (deep verify warned — normal for dev-signed appex)"

# ── 6. Package
log "packaging → $OUT_IPA"
rm -f "$OUT_IPA"
( cd "$STAGE/.." && zip -qry "$OUT_IPA" Payload )
log "  $(du -h "$OUT_IPA" | cut -f1)  build $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist")"

# ── 7. Install to the device(s) the profile provisions
if [ "$INSTALL" = 1 ]; then
  UDIDS=$(python3 - "$PROF_XML" <<'PY'
import plistlib, sys
d = plistlib.load(open(sys.argv[1],'rb'))
print(' '.join(d.get('ProvisionedDevices', []) or []))
PY
)
  ok=0
  for u in ${=UDIDS}; do
    if xcrun devicectl list devices 2>/dev/null | grep -q "$u.*available"; then
      log "installing to $u…"
      if xcrun devicectl device install app --device "$u" "$OUT_IPA" > /tmp/wander-install.log 2>&1; then
        log "  ✓ installed"; ok=1
      else
        tail -6 /tmp/wander-install.log
        log "  ✗ install failed (device locked? unlock and re-run with --no-build)"
      fi
    fi
  done
  [ "$ok" = 1 ] || log "no provisioned device connected/unlocked — signed IPA is ready at $OUT_IPA"
fi
log "done."
