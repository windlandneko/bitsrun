import Foundation
import Network
import SystemConfiguration

struct Ethernet: Sendable {
  let interface: NWInterface
  let address: String

  static func connected(_ interfaces: [NWInterface], store: SCDynamicStore?) -> [Ethernet] {
    var seen: Set<String> = []
    return interfaces.compactMap { interface in
      guard interface.type == .wiredEthernet, seen.insert(interface.name).inserted else {
        return nil
      }
      let prefix = "State:/Network/Interface/\(interface.name)"
      let link = SCDynamicStoreCopyValue(store, "\(prefix)/Link" as CFString) as? [String: Any]
      guard link?["Active"] as? Bool != false else { return nil }
      let key = "\(prefix)/IPv4" as CFString
      guard let state = SCDynamicStoreCopyValue(store, key) as? [String: Any],
        let addresses = state["Addresses"] as? [String],
        let address = addresses.first(where: { IPv4Address($0) != nil })
      else { return nil }
      return Ethernet(interface: interface, address: address)
    }.sorted { $0.interface.name < $1.interface.name }
  }
}

struct HTTPClient: Sendable {
  let ethernet: Ethernet

  func get(_ path: String, query: [String: String]) async throws -> Data {
    try Task.checkCancellation()
    guard let address = IPv4Address(ethernet.address) else { throw Failure.addressChanged }
    let target = try Self.target(path, query: query)
    let request = Data(
      ("GET \(target) HTTP/1.1\r\nHost: 10.0.0.55\r\n"
        + "Accept-Encoding: identity\r\nConnection: close\r\n\r\n").utf8
    )
    let parameters = NWParameters.tcp
    parameters.requiredInterface = ethernet.interface
    parameters.requiredInterfaceType = .wiredEthernet
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(address), port: .any)
    let connection = NWConnection(host: "10.0.0.55", port: 80, using: parameters)
    let data = try await HTTPExchange(connection: connection, request: request).response()
    try Task.checkCancellation()
    return data
  }

  static func target(_ path: String, query: [String: String]) throws -> String {
    var url = URLComponents()
    url.path = path
    url.queryItems = query.sorted { $0.key < $1.key }.map {
      URLQueryItem(name: $0.key, value: $0.value)
    }
    // URLComponents preserves '+'; the portal interprets it as a form space.
    url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    guard let target = url.string else { throw Failure.response }
    return target
  }
}

// Network.framework delivers every callback on this private queue. Cancellation,
// timeout and completion also enter that queue, so the continuation resumes once.
final class HTTPExchange: @unchecked Sendable {
  private let connection: NWConnection
  private let request: Data
  private let queue = DispatchQueue(label: "local.bitsrun.http")
  private var continuation: CheckedContinuation<Data, any Error>?
  private var buffer = Data()
  private var finished = false

  init(connection: NWConnection, request: Data) {
    self.connection = connection
    self.request = request
  }

  func response() async throws -> Data {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        queue.async {
          guard !self.finished else {
            continuation.resume(throwing: CancellationError())
            return
          }
          self.continuation = continuation
          self.start()
        }
      }
    } onCancel: {
      self.queue.async { self.finish(.failure(CancellationError())) }
    }
  }

  private func start() {
    queue.asyncAfter(deadline: .now() + 5) { self.finish(.failure(Failure.network)) }
    connection.stateUpdateHandler = { state in
      switch state {
      case .ready:
        self.connection.send(
          content: self.request,
          completion: .contentProcessed { error in
            if error != nil { self.finish(.failure(Failure.network)) } else { self.receive() }
          })
      case .failed, .waiting:
        self.finish(.failure(Failure.network))
      default: break
      }
    }
    connection.start(queue: queue)
  }

  private func receive() {
    guard !finished else { return }
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
      data, _, complete, error in
      if let data { self.buffer.append(data) }
      do {
        if let body = try HTTPResponse.body(self.buffer, complete: complete) {
          self.finish(.success(body))
        } else if error != nil {
          self.finish(.failure(Failure.network))
        } else {
          self.receive()
        }
      } catch { self.finish(.failure(error)) }
    }
  }

  private func finish(_ result: Result<Data, any Error>) {
    guard !finished else { return }
    finished = true
    connection.stateUpdateHandler = nil
    connection.cancel()
    continuation?.resume(with: result)
    continuation = nil
  }
}

// Only the portal's HTTP/1.x subset is needed: fixed length, chunked, or EOF.
// Bound response sizes and reject redirects rather than sending credentials elsewhere.
enum HTTPResponse {
  static func body(_ bytes: Data, complete: Bool) throws -> Data? {
    guard bytes.count <= 1_048_576 else { throw Failure.response }
    let separator = Data("\r\n\r\n".utf8)
    guard let boundary = bytes.range(of: separator) else {
      guard !complete, bytes.count <= 65_536 else { throw Failure.response }
      return nil
    }
    guard boundary.lowerBound <= 65_536 else { throw Failure.response }
    let lines = String(decoding: bytes[..<boundary.lowerBound], as: UTF8.self)
      .components(separatedBy: "\r\n")
    let status = lines[0].split(separator: " ")
    guard status.count >= 2, ["HTTP/1.0", "HTTP/1.1"].contains(String(status[0])),
      let code = Int(status[1]), (200..<300).contains(code)
    else { throw Failure.response }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { throw Failure.response }
      let key = line[..<colon].lowercased()
      guard !key.isEmpty else { throw Failure.response }
      if ["content-length", "transfer-encoding", "content-encoding"].contains(key),
        headers[key] != nil
      {
        throw Failure.response
      }
      headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    let payload = Data(bytes[boundary.upperBound...])
    guard headers["content-encoding"] == nil || headers["content-encoding"] == "identity" else {
      throw Failure.response
    }
    if let transfer = headers["transfer-encoding"] {
      guard transfer.lowercased() == "chunked", headers["content-length"] == nil else {
        throw Failure.response
      }
      return try chunks(payload, complete: complete)
    }
    if let length = headers["content-length"] {
      guard let count = Int(length), (0...1_048_576).contains(count) else { throw Failure.response }
      guard payload.count >= count else {
        if complete { throw Failure.response }
        return nil
      }
      return payload.prefix(count)
    }
    return complete ? payload : nil
  }

  private static func chunks(_ bytes: Data, complete: Bool) throws -> Data? {
    let newline = Data("\r\n".utf8)
    var cursor = bytes.startIndex
    var result = Data()
    while let line = bytes.range(of: newline, in: cursor..<bytes.endIndex) {
      let sizeText = String(decoding: bytes[cursor..<line.lowerBound], as: UTF8.self)
        .split(separator: ";", omittingEmptySubsequences: false)[0]
      guard let size = Int(sizeText, radix: 16), size >= 0, size <= 1_048_576 else {
        throw Failure.response
      }
      cursor = line.upperBound
      if size == 0 {
        let trailer = bytes[cursor...]
        if trailer.starts(with: newline) || trailer.range(of: Data("\r\n\r\n".utf8)) != nil {
          return result
        }
        break
      }
      guard size + 2 <= bytes.endIndex - cursor else { break }
      guard bytes[(cursor + size)..<(cursor + size + 2)] == newline else { throw Failure.response }
      result.append(bytes[cursor..<(cursor + size)])
      cursor += size + 2
    }
    if complete { throw Failure.response }
    return nil
  }
}
