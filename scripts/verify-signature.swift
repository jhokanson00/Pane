// Checks a Sparkle EdDSA signature with the public key alone (what every copy of Pane
// holds as SUPublicEDKey), without the keychain.
//
//   swift scripts/verify-signature.swift <public key> appcast.xml               # a signed feed
//   swift scripts/verify-signature.swift <public key> Pane-1.1.0.dmg <signature>
//
// Prints VALID and exits 0; otherwise says why and exits 1 (wrong signature), 2 (the
// feed isn't signed) or 3 (bad input).
import CryptoKit
import Foundation

func fail(_ message: String, _ code: Int32) -> Never {
    print(message)
    exit(code)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 || arguments.count == 4 else {
    fail("usage: verify-signature.swift <public key> <file> [<signature>]", 3)
}
guard let keyData = Data(base64Encoded: arguments[1]),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
else { fail("Not an Ed25519 public key: \(arguments[1])", 3) }
guard var data = try? Data(contentsOf: URL(fileURLWithPath: arguments[2])) else {
    fail("Can't read \(arguments[2])", 3)
}

var signature = arguments.count == 4 ? arguments[3] : ""
if arguments.count == 3 {
    // sign_update ends a feed with this block, signing every byte before it. Sparkle
    // reads the last block and its last edSignature line, so this does too.
    guard let start = data.range(of: Data("<!-- sparkle-signatures:\n".utf8), options: .backwards),
          let end = data.range(of: Data("-->".utf8), in: start.upperBound..<data.endIndex)
    else { fail("UNSIGNED: \(arguments[2]) has no signature block", 2) }
    let block = String(decoding: data[start.upperBound..<end.lowerBound], as: UTF8.self)
    signature = block.split(separator: "\n").last { $0.hasPrefix("edSignature:") }
        .map { $0.dropFirst("edSignature:".count).trimmingCharacters(in: .whitespaces) } ?? ""
    data = data.subdata(in: data.startIndex..<start.lowerBound)
}
guard let signatureData = Data(base64Encoded: signature), signatureData.count == 64 else {
    fail("Not an Ed25519 signature: \(signature)", 3)
}
guard key.isValidSignature(signatureData, for: data) else {
    fail("INVALID: \(arguments[2]) isn't signed by that key", 1)
}
print("VALID: \(arguments[2])")
