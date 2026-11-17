#!/bin/zsh
# Pubblica una nuova versione su GitHub: chi ha l'app riceve l'aggiornamento al prossimo avvio.
# Uso:  1. aumenta CFBundleShortVersionString in Info.plist (es. 1.1)
#       2. ./release.sh "Cosa c'è di nuovo"
set -e
cd "${0:A:h}"
VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
NOTES="${1:-Miglioramenti e correzioni.}"
[[ -z "$(git status --porcelain)" ]] || { echo "Ci sono modifiche non salvate in git: fai prima un commit."; exit 1; }
gh release view "v$VER" >/dev/null 2>&1 && { echo "La versione $VER esiste già su GitHub: aumenta il numero in Info.plist."; exit 1; }
security find-generic-password -s telepromptrius-update -a "$USER" >/dev/null 2>&1 || { echo "Manca la chiave di firma: lancia tools/keygen.sh"; exit 1; }
./dist.sh
git push origin HEAD
gh release create "v$VER" dist/* --title "Telepromptrius $VER" --notes "$NOTES"
echo "Pubblicata la versione $VER."
