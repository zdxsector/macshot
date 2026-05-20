#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

PROJECT="${PROJECT:-macshot.xcodeproj}"
SCHEME="${SCHEME:-macshot}"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-build}"
RELEASE_DIR="${RELEASE_DIR:-build/release}"
APP_NAME="${APP_NAME:-macshot}"
DMG_NAME="${DMG_NAME:-MacShot.dmg}"
ZIP_NAME="${ZIP_NAME:-MacShot.zip}"
VERSION="${VERSION:-}"
BUILD_NUMBER="${BUILD_NUMBER:-}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
KEYCHAIN_PATH="${KEYCHAIN_PATH:-}"
SKIP_DMG="${SKIP_DMG:-0}"
SKIP_SIGN="${SKIP_SIGN:-0}"
STRIP_XATTRS="${STRIP_XATTRS:-1}"

APP_BUNDLE="${APP_NAME}.app"
BUILT_APP="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/${APP_BUNDLE}"
RELEASE_APP="${RELEASE_DIR}/${APP_BUNDLE}"
ZIP_PATH="${RELEASE_DIR}/${ZIP_NAME}"
DMG_PATH="${RELEASE_DIR}/${DMG_NAME}"
STAGING_DIR="${RELEASE_DIR}/dmg-staging"

log() {
  printf '[build] %s\n' "$*"
}

fail() {
  printf '[build] error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

copy_without_extended_attributes() {
  require_command ditto
  ditto --noextattr --noqtn "$1" "$2"
}

strip_extended_attributes() {
  [[ "$STRIP_XATTRS" == "1" ]] || return 0
  command -v xattr >/dev/null 2>&1 || return 0

  xattr -cr "$1"
}

check_xcode() {
  require_command xcodebuild

  local developer_dir
  developer_dir="$(xcode-select -p 2>/dev/null || true)"
  if [[ -z "$developer_dir" || "$developer_dir" == *"/CommandLineTools" ]]; then
    fail "xcodebuild requires full Xcode. Run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  fi
}

copy_release_app() {
  [[ -d "$BUILT_APP" ]] || fail "built app not found at $BUILT_APP"

  rm -rf "$RELEASE_APP"
  copy_without_extended_attributes "$BUILT_APP" "$RELEASE_APP"
  strip_extended_attributes "$RELEASE_APP"
  log "app: $RELEASE_APP"
}

sign_app() {
  [[ "$SKIP_SIGN" != "1" ]] || {
    log "signing skipped by SKIP_SIGN=1"
    return 0
  }

  require_command codesign

  local app="$RELEASE_APP"
  local identity="$SIGNING_IDENTITY"
  local use_hardened_runtime=1
  if [[ -z "$identity" ]]; then
    identity="-"
    use_hardened_runtime=0
    log "ad-hoc signing app; set SIGNING_IDENTITY to use a Developer ID identity"
  else
    log "signing app with identity: $identity"
  fi

  local codesign_args=(--force --sign "$identity")
  if [[ "$use_hardened_runtime" == "1" ]]; then
    codesign_args+=(--options runtime)
  fi
  if [[ -n "$KEYCHAIN_PATH" ]]; then
    codesign_args+=(--keychain "$KEYCHAIN_PATH")
  fi

  find "$app/Contents" -name "*.xpc" -print0 | while IFS= read -r -d '' xpc; do
    log "signing XPC: $xpc"
    codesign "${codesign_args[@]}" "$xpc"
  done

  find "$app/Contents" -name "*.app" -print0 | while IFS= read -r -d '' helper; do
    log "signing helper app: $helper"
    codesign "${codesign_args[@]}" "$helper"
  done

  local autoupdate="$app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
  if [[ -f "$autoupdate" ]]; then
    log "signing Sparkle Autoupdate"
    codesign "${codesign_args[@]}" "$autoupdate"
  fi

  find "$app/Contents" -name "*.dylib" -print0 | while IFS= read -r -d '' dylib; do
    log "signing dylib: $dylib"
    codesign "${codesign_args[@]}" "$dylib"
  done

  find "$app/Contents" -name "*.framework" -print0 | while IFS= read -r -d '' framework; do
    log "signing framework: $framework"
    codesign "${codesign_args[@]}" "$framework"
  done

  codesign "${codesign_args[@]}" \
    --entitlements macshot/macshot.entitlements \
    "$app"

  codesign --verify --deep --strict "$app"

  find "$app/Contents" -name "*.xpc" -print0 | while IFS= read -r -d '' xpc; do
    if codesign -d --entitlements - "$xpc" 2>&1 | grep -q "app-sandbox"; then
      fail "$xpc has sandbox entitlements; Sparkle updates can fail"
    fi
  done
}

create_zip() {
  require_command ditto
  rm -f "$ZIP_PATH"
  strip_extended_attributes "$RELEASE_APP"
  ditto -c -k --keepParent --noextattr --noqtn "$RELEASE_APP" "$ZIP_PATH"
  strip_extended_attributes "$ZIP_PATH"
  log "zip: $ZIP_PATH"
}

prepare_dmg_staging() {
  rm -rf "$STAGING_DIR"
  mkdir -p "$STAGING_DIR"
  copy_without_extended_attributes "$RELEASE_APP" "$STAGING_DIR/$APP_BUNDLE"
  strip_extended_attributes "$STAGING_DIR/$APP_BUNDLE"
  ln -s /Applications "$STAGING_DIR/Applications"
}

create_dmg_with_create_dmg() {
  command -v create-dmg >/dev/null 2>&1 || return 1

  set +e
  create-dmg \
    --volname "macshot" \
    --background "assets/dmg-background.png" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "$APP_BUNDLE" 150 185 \
    --app-drop-link 450 185 \
    --no-internet-enable \
    --hide-extension "$APP_BUNDLE" \
    "$DMG_PATH" \
    "$STAGING_DIR"
  local status=$?
  set -e

  if [[ "$status" -eq 0 || "$status" -eq 2 ]]; then
    [[ -f "$DMG_PATH" ]] && return 0
    log "create-dmg exited with $status but did not produce $DMG_PATH"
    return 1
  fi

  log "create-dmg failed with exit code $status; falling back to hdiutil"
  return 1
}

create_dmg_with_hdiutil() {
  require_command hdiutil

  hdiutil create \
    -volname "macshot" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null
}

create_dmg() {
  [[ "$SKIP_DMG" != "1" ]] || {
    log "DMG skipped by SKIP_DMG=1"
    return 0
  }

  rm -f "$DMG_PATH"
  prepare_dmg_staging

  if ! create_dmg_with_create_dmg; then
    create_dmg_with_hdiutil
  fi

  rm -rf "$STAGING_DIR"
  [[ -f "$DMG_PATH" ]] || fail "DMG was not created at $DMG_PATH"
  strip_extended_attributes "$DMG_PATH"
  log "dmg: $DMG_PATH"
}

main() {
  [[ -d "$PROJECT" ]] || fail "project not found: $PROJECT"
  check_xcode

  mkdir -p "$RELEASE_DIR"

  local build_settings=()
  if [[ -n "$VERSION" ]]; then
    build_settings+=(MARKETING_VERSION="$VERSION")
  fi
  if [[ -n "$BUILD_NUMBER" ]]; then
    build_settings+=(CURRENT_PROJECT_VERSION="$BUILD_NUMBER")
  fi

  log "resolving packages"
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    -resolvePackageDependencies

  log "building ${SCHEME} ${CONFIGURATION}"
  if [[ -n "$VERSION" || -n "$BUILD_NUMBER" ]]; then
    xcodebuild \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -configuration "$CONFIGURATION" \
      -derivedDataPath "$DERIVED_DATA_PATH" \
      CODE_SIGN_IDENTITY="" \
      CODE_SIGNING_REQUIRED=NO \
      CODE_SIGNING_ALLOWED=NO \
      "${build_settings[@]}" \
      build
  else
    xcodebuild \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -configuration "$CONFIGURATION" \
      -derivedDataPath "$DERIVED_DATA_PATH" \
      CODE_SIGN_IDENTITY="" \
      CODE_SIGNING_REQUIRED=NO \
      CODE_SIGNING_ALLOWED=NO \
      build
  fi

  copy_release_app
  sign_app
  create_zip
  create_dmg

  log "release artifacts written to $RELEASE_DIR"
}

main "$@"
