#!/bin/zsh
# Compila Telepromptrius.
# Uso:  ./build.sh                 compila per il chip di questo Mac e installa in /Applications
#       ./build.sh --universal     versione universale (chip Apple + Intel), usata da dist.sh
#       ./build.sh --no-install    crea solo l'app in una cartella temporanea
set -e
cd "${0:A:h}"
UNIVERSAL=0; INSTALL=1
for a in "$@"; do
  case $a in
    --universal) UNIVERSAL=1 ;;
    --no-install) INSTALL=0 ;;
  esac
done
BUILD="${TMPDIR:-/tmp}/telepromptrius-build"
APP="$BUILD/Telepromptrius.app"
rm -rf "$BUILD" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
FLAGS=(-O -swift-version 5 -parse-as-library)
if (( UNIVERSAL )); then
  swiftc $FLAGS -target arm64-apple-macos26.0  main.swift -o "$BUILD/arm64"
  swiftc $FLAGS -target x86_64-apple-macos26.0 main.swift -o "$BUILD/x86_64"
  lipo -create "$BUILD/arm64" "$BUILD/x86_64" -output "$APP/Contents/MacOS/Telepromptrius"
  rm -f "$BUILD/arm64" "$BUILD/x86_64"
else
  swiftc $FLAGS -target "$(uname -m)-apple-macos26.0" main.swift -o "$APP/Contents/MacOS/Telepromptrius"
fi
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Creata $APP ($(lipo -archs "$APP/Contents/MacOS/Telepromptrius"))"
if (( INSTALL )); then
  pkill -x Telepromptrius 2>/dev/null && sleep 1 || true
  rm -rf /Applications/Telepromptrius.app
  cp -R "$APP" /Applications/
  rm -rf "$BUILD"
  echo "Installata in /Applications"
fi
