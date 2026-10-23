#!/usr/bin/env bash
set -euo pipefail

# Script per compilazione locale su macOS (opzionale — non necessario se usi GitHub Actions)
# Uso:
#   ./scripts/build_macos.sh                              -> genera solo dist/FocusFB.dylib + .deb
#   ./scripts/build_macos.sh /percorso/Facebook.ipa       -> genera anche dist/FocusFB_Patched.ipa

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${PROJECT_DIR}/dist"
INPUT_IPA="${1:-}"
DISPLAY_NAME="${DISPLAY_NAME:-Facebook}"
BUNDLE_ID="${BUNDLE_ID:-com.facebook.Facebook}"

mkdir -p "${DIST_DIR}"

if ! command -v ldid >/dev/null 2>&1; then
  echo "[*] Installazione dipendenze Homebrew (make, ldid-procursus, dpkg)..."
  brew install make ldid-procursus dpkg
fi

if [[ -d "$(brew --prefix make 2>/dev/null)/libexec/gnubin" ]]; then
  export PATH="$(brew --prefix make)/libexec/gnubin:${PATH}"
fi

if [[ -z "${THEOS:-}" ]]; then
  export THEOS="${PROJECT_DIR}/.theos_toolchain"
fi

if [[ ! -d "${THEOS}/makefiles" ]]; then
  echo "[*] Clonazione Theos..."
  git clone --depth 1 --recurse-submodules https://github.com/theos/theos.git "${THEOS}"
fi

echo "[*] Compilazione FocusFB.dylib (arm64, iOS 15.0+)..."
make -C "${PROJECT_DIR}" ARCHS=arm64 FINALPACKAGE=1 clean all

DYLIB_SRC=""
for candidate in \
  "${PROJECT_DIR}/.theos/obj/arm64/FocusFB.dylib" \
  "${PROJECT_DIR}/.theos/obj/FocusFB.dylib" \
  "${PROJECT_DIR}/.theos/obj/debug/arm64/FocusFB.dylib" \
  "${PROJECT_DIR}/.theos/obj/debug/FocusFB.dylib"; do
  if [[ -f "${candidate}" ]]; then
    DYLIB_SRC="${candidate}"
    break
  fi
done

if [[ -z "${DYLIB_SRC}" ]]; then
  echo "[ERRORE] FocusFB.dylib non trovato dopo la compilazione!"
  exit 1
fi

cp "${DYLIB_SRC}" "${DIST_DIR}/FocusFB.dylib"
install_name_tool -id "@rpath/FocusFB.dylib" "${DIST_DIR}/FocusFB.dylib"
ldid -S "${DIST_DIR}/FocusFB.dylib"

python3 "${PROJECT_DIR}/scripts/verify_dylib.py" "${DIST_DIR}/FocusFB.dylib"

if [[ -n "${INPUT_IPA}" ]]; then
  if ! command -v cyan >/dev/null 2>&1; then
    echo "[*] Installazione cyan (pyzule-rw)..."
    pipx install --force https://github.com/asdfzxcvbn/pyzule-rw/archive/main.zip
  fi
  echo "[*] Iniezione di FocusFB.dylib nell'IPA..."
  cyan -i "${INPUT_IPA}" \
       -o "${DIST_DIR}/FocusFB_Patched.ipa" \
       -u -w -e -q -s --overwrite \
       -n "${DISPLAY_NAME}" \
       -b "${BUNDLE_ID}" \
       -f "${DIST_DIR}/FocusFB.dylib"
  echo "[OK] IPA generata in: ${DIST_DIR}/FocusFB_Patched.ipa"
fi

echo "[OK] Build completata in: ${DIST_DIR}"
ls -lh "${DIST_DIR}"
