// Firma Ed25519 dei pacchetti di aggiornamento.
//   swift tools/sign.swift keygen            -> stampa "privata pubblica" in base64
//   TP_KEY=<privata> swift tools/sign.swift sign <file>   -> stampa la firma in base64
//   swift tools/sign.swift verify <file> <firma-b64> <pubblica-b64>
import Foundation
import CryptoKit

let a = CommandLine.arguments
func die(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }

switch a.count > 1 ? a[1] : "" {
case "keygen":
    let k = Curve25519.Signing.PrivateKey()
    print(k.rawRepresentation.base64EncodedString(), k.publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard a.count > 2, let b64 = ProcessInfo.processInfo.environment["TP_KEY"], let raw = Data(base64Encoded: b64),
          let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { die("chiave privata mancante (TP_KEY)") }
    guard let data = FileManager.default.contents(atPath: a[2]) else { die("file non trovato") }
    print(try! k.signature(for: data).base64EncodedString())
case "verify":
    guard a.count > 4, let data = FileManager.default.contents(atPath: a[2]),
          let sig = Data(base64Encoded: a[3]), let pub = Data(base64Encoded: a[4]),
          let k = try? Curve25519.Signing.PublicKey(rawRepresentation: pub) else { die("argomenti non validi") }
    if k.isValidSignature(sig, for: data) { print("firma valida") } else { die("firma NON valida") }
default:
    die("uso: sign.swift keygen | sign <file> | verify <file> <firma> <pubblica>")
}
