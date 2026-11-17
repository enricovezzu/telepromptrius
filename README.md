# Telepromptrius

Teleprompter per Mac: sul tuo schermo il testo è dritto, sullo schermo esteso è specchiato nel modo che scegli
(orizzontale per i teleprompter con vetro, verticale o ruotato di 180°).

- Libreria dei testi con ricerca, importazione da Word/RTF/testo
- Testi sincronizzati in **iCloud Drive → Telepromptrius** (un file `.txt` per testo, modificabili anche da iPhone/iPad)
- Scorrimento fluido a 120 Hz, trackpad, telecomando da presentazione (Pagina su/giù)
- Mini monitor che mostra lo schermo esteso come appare davvero
- Aggiornamenti automatici dalle release di GitHub, con firma verificata

Richiede macOS 26 o successivo (chip Apple o Intel).

## Installare
Scarica `Telepromptrius-<versione>.dmg` dall'ultima [release](../../releases/latest), trascina l'app in Applicazioni.
La prima volta: Impostazioni di Sistema → Privacy e sicurezza → **Apri comunque** (l'app non è notarizzata da Apple).
Dalle volte successive si aggiorna da sola.

## Privacy
L'app non raccoglie né invia dati. Per gli aggiornamenti fa una richiesta anonima all'API pubblica di GitHub
(`releases/latest` di questo repository). I testi restano sul tuo Mac e nel tuo iCloud Drive.

## Sviluppo
Serve solo Xcode Command Line Tools (`xcode-select --install`).

| Comando | Cosa fa |
|---|---|
| `./build.sh` | compila per il chip di questo Mac e installa in /Applications |
| `./dist.sh` | crea in `dist/` il DMG universale, il pacchetto di aggiornamento `.zip` e la sua firma |
| `./release.sh "novità"` | pubblica su GitHub la versione scritta in `Info.plist` (chi ha l'app la riceve al prossimo avvio) |
| `tools/keygen.sh` | una volta sola: crea la chiave di firma degli aggiornamenti (privata nel Portachiavi, pubblica in `Info.plist`) |

Per una nuova versione: aumenta `CFBundleShortVersionString` in `Info.plist`, fai il commit, poi `./release.sh "cosa cambia"`.

**La chiave privata di firma sta solo nel Portachiavi di questo Mac** (voce "Telepromptrius – chiave aggiornamenti").
Se la perdi, chi ha l'app non potrà più aggiornarsi da sola e dovrà reinstallarla a mano.

Prova veloce: `open -a Telepromptrius --args --prompter` apre direttamente l'ultimo testo.

## Licenza
MIT, vedi [LICENSE](LICENSE).
