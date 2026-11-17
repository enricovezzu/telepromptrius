#!/bin/zsh
# Crea i file da distribuire in dist/:
#   Telepromptrius-<ver>.dmg      installer per chi la installa la prima volta
#   Telepromptrius-<ver>.zip      pacchetto per l'aggiornamento automatico
#   Telepromptrius-<ver>.zip.sig  firma del pacchetto (chiave nel Portachiavi)
set -e
cd "${0:A:h}"
./build.sh --universal --no-install
BUILD="${TMPDIR:-/tmp}/telepromptrius-build"
VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
OUT=dist; rm -rf $OUT; mkdir -p $OUT
STAGE="$BUILD/dmg"; mkdir -p "$STAGE"
cp -R "$BUILD/Telepromptrius.app" "$STAGE/"
ln -s /Applications "$STAGE/Applicazioni"
cp tools/Leggimi-prima-apertura.txt "$STAGE/Leggimi - prima apertura.txt"
hdiutil create -volname "Telepromptrius" -srcfolder "$STAGE" -ov -format UDZO "$OUT/Telepromptrius-$VER.dmg" >/dev/null 2>&1
cp "$OUT/Telepromptrius-$VER.dmg" "$OUT/Telepromptrius.dmg"   # nome fisso per il bottone Scarica del README
ditto -c -k --keepParent "$BUILD/Telepromptrius.app" "$OUT/Telepromptrius-$VER.zip"
if KEY=$(security find-generic-password -s telepromptrius-update -a "$USER" -w 2>/dev/null); then
  TP_KEY="$KEY" swift tools/sign.swift sign "$OUT/Telepromptrius-$VER.zip" > "$OUT/Telepromptrius-$VER.zip.sig"
  PUB=$(/usr/libexec/PlistBuddy -c "Print :TPUpdatePublicKey" Info.plist)
  swift tools/sign.swift verify "$OUT/Telepromptrius-$VER.zip" "$(cat $OUT/Telepromptrius-$VER.zip.sig)" "$PUB"
else
  echo "ATTENZIONE: nessuna chiave di firma (lancia tools/keygen.sh): il pacchetto di aggiornamento non è firmato."
fi
rm -rf "$BUILD"
echo "Creati in $OUT/:"; ls -1 $OUT
