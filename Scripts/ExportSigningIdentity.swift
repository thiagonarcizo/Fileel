import CryptoKit
import Foundation
import Security

// export only the reviewed developer id identity, never the other teams in the keychain
guard CommandLine.arguments.count == 2,
      let password = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8),
      password.count >= 24 else {
    fputs("provide an output path and a strong export password on standard input\n", stderr)
    exit(64)
}
let fingerprint = "A9B9CCDD1D529601EF14753A1DF6B86F4663E956"
let query = [kSecClass: kSecClassIdentity, kSecReturnRef: true, kSecMatchLimit: kSecMatchLimitAll] as CFDictionary
var result: CFTypeRef?
guard SecItemCopyMatching(query, &result) == errSecSuccess, let identities = result as? [SecIdentity] else {
    fputs("no signing identity is available\n", stderr)
    exit(65)
}
for identity in identities {
    var certificate: SecCertificate?
    guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { continue }
    let digest = Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data)
        .map { String(format: "%02X", $0) }.joined()
    guard digest == fingerprint else { continue }
    let passphrase = password as CFString
    var parameters = SecItemImportExportKeyParameters()
    parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
    parameters.passphrase = Unmanaged.passUnretained(passphrase)
    var exported: CFData?
    let status = SecItemExport(identity, .formatPKCS12, [], &parameters, &exported)
    guard status == errSecSuccess, let exported else {
        fputs("the selected identity could not be exported (\(status))\n", stderr)
        exit(65)
    }
    let path = URL(fileURLWithPath: CommandLine.arguments[1])
    do {
        guard !FileManager.default.fileExists(atPath: path.path) else {
            fputs("choose a new export path\n", stderr)
            exit(73)
        }
        try (exported as Data).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        print("the selected identity was exported with password protection")
        exit(0)
    } catch {
        fputs("the encrypted export could not be saved\n", stderr)
        exit(74)
    }
}
fputs("the expected developer id certificate was not found\n", stderr)
exit(65)
