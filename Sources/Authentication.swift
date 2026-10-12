import CryptoKit
import Foundation

struct Credentials: Codable, Sendable {
  let username: String
  let password: String
}

enum Failure: Error, Equatable {
  case network
  case response
  case rejected
  case addressChanged
  case credentials
  case keychain(Int32)

  var retryable: Bool {
    self == .network || self == .response || self == .addressChanged
  }

  var message: String {
    switch self {
    case .network, .response, .addressChanged:
      "校园网认证服务暂不可用，请检查网络。"
    case .rejected:
      "校园网拒绝认证，请检查账号或密码。"
    case .credentials, .keychain:
      "无法读取校园网凭据，请重新运行 bitsrun install。"
    }
  }
}

// Deep-LAN's SRBX1 wire format, preserved from BITNP/bitsrun.
// Keep JSON ordering and ASCII escaping identical to the upstream implementation.
enum Srun {
  static let accessController = "43"
  private static let alphabet = Array(
    "LVoJPiCN2R8G90yg+hmFHuacZ1OWMnrsSTXkYpUq/3dlbfKwv6xztjI7DeBE45QA".utf8
  )
  private static let standard = Array(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8
  )

  static func parameters(
    credentials: Credentials, address: String, challenge: String
  ) -> [String: String] {
    let digest = HMAC<Insecure.MD5>.authenticationCode(
      for: Data(), using: SymmetricKey(data: Data(challenge.utf8))
    ).map { String(format: "%02x", $0) }.joined()
    let fields = [
      ("username", credentials.username), ("password", credentials.password),
      ("acid", accessController), ("ip", address), ("enc_ver", "srun_bx1"),
    ]
    let json = "{" + fields.map { quote($0.0) + ":" + quote($0.1) }.joined(separator: ",") + "}"
    let info = "{SRBX1}" + encode(Data(json.utf8), key: Data(challenge.utf8))
    let checksumInput = [
      credentials.username, digest, accessController, address, "200", "1", info,
    ].map { challenge + $0 }.joined()
    let checksum = Insecure.SHA1.hash(data: Data(checksumInput.utf8))
      .map { String(format: "%02x", $0) }.joined()
    return [
      "callback": "jsonp", "action": "login", "username": credentials.username,
      "password": "{MD5}" + digest, "ac_id": accessController, "ip": address,
      "type": "1", "n": "200", "info": info, "chksum": checksum,
    ]
  }

  private static func quote(_ string: String) -> String {
    var result = "\""
    for unit in string.utf16 {
      switch unit {
      case 8: result += "\\b"
      case 9: result += "\\t"
      case 10: result += "\\n"
      case 12: result += "\\f"
      case 13: result += "\\r"
      case 34: result += "\\\""
      case 92: result += "\\\\"
      case 32...126: result += String(UnicodeScalar(unit)!)
      default: result += String(format: "\\u%04x", unit)
      }
    }
    return result + "\""
  }

  private static func words(_ data: Data) -> [UInt32] {
    var result = [UInt32](repeating: 0, count: (data.count + 3) / 4)
    for (index, byte) in data.enumerated() {
      result[index / 4] |= UInt32(byte) << ((index % 4) * 8)
    }
    return result
  }

  private static func encode(_ data: Data, key: Data) -> String {
    var values = words(data)
    values.append(UInt32(data.count))
    var keyWords = words(key)
    keyWords += Array(repeating: 0, count: max(0, 4 - keyWords.count))
    let last = values.count - 1
    var z = values[last]
    var sum: UInt32 = 0
    for _ in 0..<(6 + 52 / values.count) {
      sum &+= 0x9E37_79B9
      let selector = Int(sum >> 2 & 3)
      for index in values.indices {
        let y = values[index == last ? 0 : index + 1]
        let mix =
          ((z >> 5) ^ (y << 2))
          &+ (((y >> 3) ^ (z << 4)) ^ (sum ^ y))
          &+ (keyWords[(index & 3) ^ selector] ^ z)
        values[index] &+= mix
        z = values[index]
      }
    }
    let bytes = values.flatMap { word in
      (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) }
    }
    let encoded = Data(bytes).base64EncodedString().utf8.map { byte in
      standard.firstIndex(of: byte).map { alphabet[$0] } ?? byte
    }
    return String(decoding: encoded, as: UTF8.self)
  }
}

enum PortalState {
  case foreignNetwork
  case unavailable
  case online
  case offline(String)
}

struct Portal: Sendable {
  let transport: HTTPClient

  func status() async throws -> PortalState {
    // Probing another wired network is normal, so failures before identification
    // remain silent. Credentials are only sent after a matching portal is found.
    let page: Data
    do {
      page = try await transport.get(
        "/srun_portal_pc", query: ["ac_id": Srun.accessController, "theme": "bit"]
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return .unavailable
    }
    let html = String(decoding: page, as: UTF8.self)
    guard html.lowercased().contains("srun"),
      ["北京理工大学", "BEIJING INSTITUTE", "www.bit.edu.cn"].contains(where: html.contains)
    else { return .foreignNetwork }

    let status: Status = try await read("/cgi-bin/rad_user_info")
    if status.userName?.isEmpty == false { return .online }
    guard let address = status.onlineIP, !address.isEmpty else { throw Failure.response }
    return .offline(address)
  }

  func login(credentials: Credentials, address: String) async throws {
    guard !credentials.username.isEmpty, !credentials.password.isEmpty else {
      throw Failure.credentials
    }
    let challenge: Challenge = try await read(
      "/cgi-bin/get_challenge", query: ["username": credentials.username, "ip": address]
    )
    guard !challenge.challenge.isEmpty else { throw Failure.response }
    try Task.checkCancellation()
    let result: LoginResult = try await read(
      "/cgi-bin/srun_portal",
      query: Srun.parameters(
        credentials: credentials, address: address, challenge: challenge.challenge)
    )
    guard result.error == "ok" else { throw Failure.rejected }
    let verified: Status = try await read("/cgi-bin/rad_user_info")
    guard verified.userName == credentials.username, verified.onlineIP == address else {
      throw Failure.response
    }
  }

  private func read<Response: Decodable>(
    _ path: String, query: [String: String] = [:]
  ) async throws -> Response {
    var query = query
    query["callback"] = "jsonp"
    return try Self.decode(await transport.get(path, query: query))
  }

  static func decode<Response: Decodable>(_ data: Data) throws -> Response {
    var text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasSuffix(";") { text.removeLast() }
    guard text.hasPrefix("jsonp("), text.hasSuffix(")") else { throw Failure.response }
    do {
      return try JSONDecoder().decode(Response.self, from: Data(text.dropFirst(6).dropLast().utf8))
    } catch { throw Failure.response }
  }
}

private struct Status: Decodable {
  let userName: String?
  let onlineIP: String?
  enum CodingKeys: String, CodingKey {
    case userName = "user_name"
    case onlineIP = "online_ip"
  }
}

private struct Challenge: Decodable {
  let challenge: String
}

private struct LoginResult: Decodable {
  let error: String
}
