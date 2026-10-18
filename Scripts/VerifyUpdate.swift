import CryptoKit
import Foundation

// check the downloaded bytes against the public key shipped in the app
guard CommandLine.arguments.count == 4,
      let publicData = Data(base64Encoded: CommandLine.arguments[2]),
      let signature = Data(base64Encoded: CommandLine.arguments[3]) else {
    fputs("usage: VerifyUpdate.swift archive public-key signature\n", stderr)
    exit(64)
}
do {
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicData)
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), options: .mappedIfSafe)
    guard key.isValidSignature(signature, for: data) else {
        fputs("the update signature does not match the shipped public key\n", stderr)
        exit(65)
    }
    print("update signature verified")
} catch {
    fputs("the update signature could not be verified\n", stderr)
    exit(65)
}
