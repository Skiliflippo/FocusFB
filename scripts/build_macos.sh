#!/usr/bin/env bash
set -euo pipefail

# Build FocusFB.dylib on macOS using Xcode iOS SDK (no Theos / Substrate required)
# Usage:
#   ./scripts/build_macos.sh                        -> builds dist/FocusFB.dylib
#   ./scripts/build_macos.sh /path/to/Facebook.ipa  -> also injects dist/FocusFB_Patched.ipa

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${PROJECT_DIR}/dist"
INPUT_IPA="${1:-}"
DISPLAY_NAME="${DISPLAY_NAME:-Facebook}"
BUNDLE_ID="${BUNDLE_ID:-com.facebook.Facebook}"

mkdir -p "${DIST_DIR}"

if ! command -v ldid >/dev/null 2>&1; then
  brew install ldid-procursus || brew install ldid
fi

SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "[*] Building FocusFB.dylib v2.5.1 (arm64) with iOS SDK: ${SDK_PATH}"

xcrun --sdk iphoneos clang++ \
  -isysroot "${SDK_PATH}" \
  -target arm64-apple-ios15.0 \
  -dynamiclib \
  -std=gnu++17 \
  -fobjc-arc \
  -fobjc-exceptions \
  -fobjc-call-cxx-cdtors \
  -O2 \
  -Wno-deprecated-declarations \
  -Wno-undeclared-selector \
  -install_name "@rpath/FocusFB.dylib" \
  -I"${PROJECT_DIR}/src" \
  "${PROJECT_DIR}/src/Tweak.mm" \
  "${PROJECT_DIR}/src/FocusFBFishhook.mm" \
  "${PROJECT_DIR}/src/FocusFBPrefs.mm" \
  "${PROJECT_DIR}/src/FocusFBSideloadFix.mm" \
  "${PROJECT_DIR}/src/FocusFBTabManager.mm" \
  "${PROJECT_DIR}/src/FocusFBSettingsViewController.mm" \
  "${PROJECT_DIR}/src/FocusFBLockManager.mm" \
  "${PROJECT_DIR}/src/FocusFBAdBlocker.mm" \
  "${PROJECT_DIR}/src/FocusFBStoriesManager.mm" \
  "${PROJECT_DIR}/src/FocusFBMediaDownloader.mm" \
  -lobjc \
  -framework Foundation \
  -framework CoreFoundation \
  -framework UIKit \
  -framework QuartzCore \
  -framework CoreGraphics \
  -framework Security \
  -framework AVFoundation \
  -framework CoreImage \
  -weak_framework CoreMedia \
  -weak_framework Photos \
  -weak_framework CoreNFC \
  -o "${DIST_DIR}/FocusFB.dylib"

ldid -S "${DIST_DIR}/FocusFB.dylib"
python3 "${PROJECT_DIR}/scripts/verify_dylib.py" "${DIST_DIR}/FocusFB.dylib"

if [[ -n "${INPUT_IPA}" ]]; then
  if ! command -v cyan >/dev/null 2>&1; then
    pipx install --force https://github.com/asdfzxcvbn/pyzule-rw/archive/main.zip
  fi
  MERGE_PLIST="${DIST_DIR}/focusfb_info_merge.plist"
  python3 - "${MERGE_PLIST}" <<'PY'
import plistlib, sys
plistlib.dump({
    "NFCReaderUsageDescription": "Scan physical NFC tag to unlock FocusFB",
    "NSCameraUsageDescription": "Scan physical QR or barcode to unlock FocusFB",
    "NSPhotoLibraryAddUsageDescription": "Save downloaded photos and videos to your Camera Roll",
    "NSPhotoLibraryUsageDescription": "Save downloaded photos and videos to your Photo Library",
}, open(sys.argv[1], "wb"))
PY
  cyan -i "${INPUT_IPA}" \
       -o "${DIST_DIR}/FocusFB_Patched.ipa" \
       -u -w -e -q -s --overwrite \
       -n "${DISPLAY_NAME}" \
       -b "${BUNDLE_ID}" \
       -l "${MERGE_PLIST}" \
       -f "${DIST_DIR}/FocusFB.dylib"
  rm -f "${MERGE_PLIST}"
  echo "[OK] Patched IPA written to: ${DIST_DIR}/FocusFB_Patched.ipa"
fi

echo "[OK] Output in: ${DIST_DIR}"
ls -lh "${DIST_DIR}"
