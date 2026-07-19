#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
CONFIGURATION_WAS_SET="${FILENEST_CONFIGURATION+x}"
CONFIGURATION="${FILENEST_CONFIGURATION:-Release}"
if [[ ( "$MODE" == "--debug" || "$MODE" == "debug" ) && -z "$CONFIGURATION_WAS_SET" ]]; then
  CONFIGURATION="Debug"
fi
APP_NAME="FileNest"
BUNDLE_ID="com.local.filenest"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/.build/DerivedData"
BUILT_APP_BUNDLE="$DERIVED_DATA/Build/Products/$CONFIGURATION/FileNest.app"
APP_BUNDLE="$HOME/Applications/FileNest.app"
STAGED_APP_BUNDLE="$HOME/Applications/.FileNest.app.staging"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/FileNest"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
SIGNING_IDENTITY="${FILENEST_SIGNING_IDENTITY:-$(
  /usr/bin/security find-identity -p codesigning -v 2>/dev/null \
    | /usr/bin/awk '/Apple Development:/ { print $2; exit }'
)}"

if [[ -z "$SIGNING_IDENTITY" ]]; then
  echo "FileNest requires a stable Apple Development signing identity." >&2
  echo "Set FILENEST_SIGNING_IDENTITY to a certificate hash from: security find-identity -p codesigning -v" >&2
  exit 1
fi

SIGNING_CERTIFICATE_NAME="$(
  /usr/bin/security find-identity -p codesigning -v 2>/dev/null \
    | /usr/bin/awk -v identity="$SIGNING_IDENTITY" '
        $2 == identity {
          sub(/^[^"]*"/, "")
          sub(/"[[:space:]]*$/, "")
          print
          exit
        }
      '
)"
DEVELOPMENT_TEAM="${FILENEST_DEVELOPMENT_TEAM:-$(
  /usr/bin/security find-certificate -c "$SIGNING_CERTIFICATE_NAME" -p 2>/dev/null \
    | /usr/bin/openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null \
    | /usr/bin/sed -E 's/.*OU=([^,]+).*/\1/'
)}"

if [[ -z "$SIGNING_CERTIFICATE_NAME" || -z "$DEVELOPMENT_TEAM" ]]; then
  echo "Unable to resolve the Apple Development certificate or team for $SIGNING_IDENTITY." >&2
  echo "Set FILENEST_SIGNING_IDENTITY and FILENEST_DEVELOPMENT_TEAM explicitly." >&2
  exit 1
fi

designated_requirement() {
  /usr/bin/codesign -d -r- "$1" 2>&1 \
    | /usr/bin/sed -n 's/^designated => //p'
}

verify_stable_signature() {
  local app="$1" details requirement
  /usr/bin/codesign --verify --deep --strict "$app"
  details="$(/usr/bin/codesign -dvvv "$app" 2>&1)"
  requirement="$(designated_requirement "$app")"
  if [[ "$details" != *"Identifier=$BUNDLE_ID"* ||
        "$details" != *"TeamIdentifier=$DEVELOPMENT_TEAM"* ||
        -z "$requirement" || "$requirement" == cdhash* ]]; then
    echo "Unstable or unexpected signature on $app" >&2
    echo "$details" >&2
    exit 1
  fi
}

remove_transient_app_bundles() {
  local root candidate
  local roots=(
    "$HOME/Library/Developer/Xcode/DerivedData"
    "$ROOT_DIR/.build"
    "/tmp"
  )

  for root in "${roots[@]}"; do
    [[ -d "$root" ]] || continue
    while IFS= read -r -d '' candidate; do
      [[ "$candidate" == "$APP_BUNDLE" ]] && continue
      "$LSREGISTER" -u "$candidate" >/dev/null 2>&1 || true
      rm -rf "$candidate"
    done < <(
      find "$root" -maxdepth 10 -type d \
        -path '*/Build/Products/*/FileNest.app' -print0 2>/dev/null
    )
  done
}

unregister_stale_launch_services_entries() {
  local candidate

  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    [[ "$candidate" == "$APP_BUNDLE" ]] && continue
    "$LSREGISTER" -u "$candidate" >/dev/null 2>&1 || true
  done < <(
    "$LSREGISTER" -dump 2>/dev/null | awk '
      /^path:/ {
        path = $0
        sub(/^path:[[:space:]]*/, "", path)
        sub(/[[:space:]]+\(0x[[:xdigit:]]+\)$/, "", path)
      }
      /^identifier:[[:space:]]+com\.local\.filenest$/ { print path }
    '
  )
}

terminate_running_app() {
  if ! pgrep -x "$APP_NAME" >/dev/null; then
    return
  fi

  /usr/bin/osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in {1..10}; do
    if ! pgrep -x "$APP_NAME" >/dev/null; then
      return
    fi
    sleep 1
  done

  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
}

terminate_running_app

xcodebuild \
  -project "$ROOT_DIR/FileNest.xcodeproj" \
  -scheme FileNest \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  build

mkdir -p "$HOME/Applications"
verify_stable_signature "$BUILT_APP_BUNDLE"

BUILT_REQUIREMENT="$(designated_requirement "$BUILT_APP_BUNDLE")"
if [[ -d "$APP_BUNDLE" ]]; then
  EXISTING_REQUIREMENT="$(designated_requirement "$APP_BUNDLE")"
  if [[ -n "$EXISTING_REQUIREMENT" &&
        "$EXISTING_REQUIREMENT" != cdhash* &&
        "$EXISTING_REQUIREMENT" != "$BUILT_REQUIREMENT" &&
        "${FILENEST_ALLOW_SIGNING_IDENTITY_CHANGE:-0}" != "1" ]]; then
    echo "Refusing to replace FileNest with a different designated requirement." >&2
    echo "Existing: $EXISTING_REQUIREMENT" >&2
    echo "New:      $BUILT_REQUIREMENT" >&2
    echo "Set FILENEST_ALLOW_SIGNING_IDENTITY_CHANGE=1 only for an intentional one-time migration." >&2
    exit 1
  fi
fi

rm -rf "$STAGED_APP_BUNDLE"
/usr/bin/ditto "$BUILT_APP_BUNDLE" "$STAGED_APP_BUNDLE"
verify_stable_signature "$STAGED_APP_BUNDLE"
rm -rf "$APP_BUNDLE"
/bin/mv "$STAGED_APP_BUNDLE" "$APP_BUNDLE"
verify_stable_signature "$APP_BUNDLE"
remove_transient_app_bundles
unregister_stale_launch_services_entries
"$LSREGISTER" -f -R -trusted "$APP_BUNDLE"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --install-only|install-only)
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    for _ in {1..10}; do
      if pgrep -x "$APP_NAME" >/dev/null; then
        exit 0
      fi
      sleep 1
    done
    echo "$APP_NAME did not remain running after launch." >&2
    exit 1
    ;;
  *)
    echo "usage: $0 [run|--install-only|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
