#!/bin/zsh
# Builds dist/Vibe Cleaner.app from the SwiftPM products and signs it ad hoc for local use.
set -euo pipefail
cd "${0:A:h}/.."
swift build -c release --product VibeCleaner
swift build -c release --product vibeclean
BIN=$(swift build -c release --show-bin-path)
APP="dist/Vibe Cleaner.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/VibeCleaner" "$APP/Contents/MacOS/VibeCleaner"
cp "$BIN/vibeclean" "$APP/Contents/MacOS/vibeclean"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -insert CFBundleLocalizations -json '["fr"]' "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/" || true
# Shortcuts only sees App Intents listed in Contents/Resources/Metadata.appintents, which Xcode extracts
# from the compiler's const values; SwiftPM emits those but does not run the extractor, so run it here.
OBJ=$(dirname "$(find .build -path '*Release/VibeCleaner-p.build/*' -name VibeCleaner.SwiftFileList | head -1)")
if PROC=$(xcrun --find appintentsmetadataprocessor 2>/dev/null) && [[ -f "$OBJ/VibeCleaner.SwiftFileList" ]]; then
  DT=$(plutil -extract LSMinimumSystemVersion raw Resources/Info.plist)
  ls "$OBJ"/*.swiftconstvalues > "$OBJ/VibeCleaner.SwiftConstValuesFileList"
  "$PROC" --toolchain-dir "${$(xcrun --find swift):h:h:h}" --module-name VibeCleaner --sdk-root "$(xcrun --show-sdk-path)" \
    --xcode-version "$(plutil -extract ProductBuildVersion raw "$(xcode-select -p)/../version.plist")" \
    --platform-family macOS --deployment-target "$DT" \
    --bundle-identifier "$(plutil -extract CFBundleIdentifier raw Resources/Info.plist)" --target-triple "$(uname -m)-apple-macos$DT" \
    --binary-file "$BIN/VibeCleaner" --source-file-list "$OBJ/VibeCleaner.SwiftFileList" \
    --swift-const-vals-list "$OBJ/VibeCleaner.SwiftConstValuesFileList" --output "$APP/Contents/Resources" \
    --compile-time-extraction --deployment-aware-processing --no-app-shortcuts-localization --quiet-warnings 2>&1 | grep -v '^20..-' || true
fi
[[ -f "$APP/Contents/Resources/Metadata.appintents/extract.actionsdata" ]] || echo "warning: no App Intents metadata, Shortcuts will not list the actions" >&2
# A stable identity keeps Full Disk Access across rebuilds: ad hoc (-) pins the grant to the binary's hash, lost at each build.
# Defaults to the first Apple Development certificate of the keychain, ad hoc when there is none.
SIGN_IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}
# Hardened runtime: no DYLD_INSERT_LIBRARIES or unsigned library can run inside a process that may hold Full Disk
# Access. The CLI is signed first, then the bundle (no --deep, which hides what is signed with which options).
# Notarization also wants a secure timestamp, which needs Apple's server: only asked for a Developer ID.
TS=(); [[ ${SIGN_IDENTITY:-} == "Developer ID Application"* ]] && TS=(--timestamp)
codesign --force --options runtime "${TS[@]}" --sign "${SIGN_IDENTITY:--}" "$APP/Contents/MacOS/vibeclean"
codesign --force --options runtime "${TS[@]}" --sign "${SIGN_IDENTITY:--}" "$APP"
# A fresh date tells Finder and Launch Services to reread the icon.
touch "$APP"
echo "$APP"
