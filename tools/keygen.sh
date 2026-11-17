#!/bin/zsh
# Una volta sola: crea la chiave di firma degli aggiornamenti.
# La privata va nel Portachiavi (servizio "telepromptrius-update"), la pubblica in Info.plist.
set -e
cd "${0:A:h}/.."
if security find-generic-password -s telepromptrius-update -a "$USER" >/dev/null 2>&1; then
  echo "La chiave esiste già nel Portachiavi: non la sostituisco."; exit 0
fi
read PRIV PUB <<< "$(swift tools/sign.swift keygen)"
security add-generic-password -s telepromptrius-update -a "$USER" -l "Telepromptrius – chiave aggiornamenti" -w "$PRIV"
/usr/libexec/PlistBuddy -c "Set :TPUpdatePublicKey $PUB" Info.plist 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :TPUpdatePublicKey string $PUB" Info.plist
echo "Chiave creata. Pubblica: $PUB"
echo "IMPORTANTE: senza la chiave privata nel Portachiavi non potrai più firmare aggiornamenti."
