import CryptoKit
import Foundation

guard CommandLine.arguments.count == 4,
      let signature = Data(base64Encoded: CommandLine.arguments[2]),
      let publicData = Data(base64Encoded: CommandLine.arguments[3]) else {
    fatalError("需要提供更新文件, 签名和公钥")
}

let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicData)
guard key.isValidSignature(signature, for: archive) else {
    fatalError("更新签名与应用内公钥不匹配")
}

print("Update signature matches the application's public key")
