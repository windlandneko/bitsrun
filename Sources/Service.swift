import AppKit
import LocalAuthentication
import Network
import OSLog
import Security
import SystemConfiguration
import UserNotifications

// One keychain item holds the small configuration; no password file or subprocess.
@MainActor
enum CredentialStore {
  private static let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "local.bitsrun.auto",
    kSecAttrAccount as String: "campus",
  ]

  static func load(interactive: Bool = false) throws -> Credentials {
    var request = query
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    let context = LAContext()
    context.interactionNotAllowed = !interactive
    request[kSecUseAuthenticationContext as String] = context
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    guard status == errSecSuccess else { throw Failure.keychain(status) }
    guard let data = result as? Data,
      let credentials = try? JSONDecoder().decode(Credentials.self, from: data),
      !credentials.username.isEmpty, !credentials.password.isEmpty
    else { throw Failure.credentials }
    return credentials
  }

  static func configure() throws {
    do {
      _ = try load(interactive: true)
      return
    } catch Failure.keychain(errSecItemNotFound) {
      // Only the first installation asks for campus credentials.
    }
    guard isatty(STDIN_FILENO) != 0 else { throw Failure.credentials }
    print("校园网账号：", terminator: "")
    fflush(nil)
    let username = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard let secret = getpass("校园网密码：") else { throw Failure.credentials }
    let password = String(cString: secret)
    memset(secret, 0, strlen(secret))
    guard !username.isEmpty, !password.isEmpty else { throw Failure.credentials }
    try save(Credentials(username: username, password: password))
  }

  private static func save(_ credentials: Credentials) throws {
    let attributes: [String: Any] = [
      kSecValueData as String: try JSONEncoder().encode(credentials),
      kSecAttrLabel as String: "bitsrun · 北京理工大学",
    ]
    var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      status = SecItemAdd(query.merging(attributes) { _, value in value } as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw Failure.keychain(status) }
  }
}

enum Notifications {
  static func authorize() async {
    let allowed = try? await UNUserNotificationCenter.current().requestAuthorization(options: [
      .alert
    ])
    if allowed != true {
      print("失败通知未启用；仍可通过系统日志查看运行结果。")
    }
  }

  static func failure(_ message: String) {
    // Notifications need the installed app's bundle identity.
    guard Bundle.main.bundleIdentifier == "local.bitsrun.auto" else { return }
    let content = UNMutableNotificationContent()
    content.title = "校园网自动登录"
    content.body = message
    UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: "login-failed", content: content, trigger: nil)
    )
  }
}

@MainActor
final class Service {
  private let logger = Logger(subsystem: "local.bitsrun.auto", category: "login")
  private let monitor = NWPathMonitor(requiredInterfaceType: .wiredEthernet)
  private var interfaces: [NWInterface] = []
  private var store: SCDynamicStore?
  private var wakeObserver: (any NSObjectProtocol)?
  private var signals: [any DispatchSourceSignal] = []
  private var task: Task<Void, Never>?
  private var connection: [String] = []
  private var notified = false
  private var running = false

  func start() throws {
    guard !running else { return }
    var context = SCDynamicStoreContext(
      version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
      retain: nil, release: nil, copyDescription: nil
    )
    let callback: SCDynamicStoreCallBack = { _, _, context in
      guard let context else { return }
      let service = Unmanaged<Service>.fromOpaque(context).takeUnretainedValue()
      MainActor.assumeIsolated { service.changed() }
    }
    guard let store = SCDynamicStoreCreate(nil, "bitsrun" as CFString, callback, &context),
      SCDynamicStoreSetNotificationKeys(
        store, ["State:/Network/Global/IPv4"] as CFArray,
        ["State:/Network/Interface/.*/Link", "State:/Network/Interface/.*/IPv4"] as CFArray
      ), SCDynamicStoreSetDispatchQueue(store, .main)
    else { throw Failure.network }
    self.store = store
    running = true
    monitor.pathUpdateHandler = { [weak self] path in
      MainActor.assumeIsolated {
        self?.interfaces = path.availableInterfaces.filter { $0.type == .wiredEthernet }
        self?.changed()
      }
    }
    monitor.start(queue: .main)
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.changed(force: true) }
    }
    for number in [SIGTERM, SIGINT] {
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
      source.setEventHandler { [weak self] in
        self?.stop()
        NSApplication.shared.terminate(nil)
      }
      source.resume()
      signals.append(source)
    }
  }

  func stop() {
    running = false
    task?.cancel()
    monitor.cancel()
    if let store { SCDynamicStoreSetDispatchQueue(store, nil) }
    if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    for source in signals { source.cancel() }
  }

  private func ethernet() -> [Ethernet] {
    Ethernet.connected(interfaces, store: store)
  }

  private func changed(force: Bool = false) {
    guard running else { return }
    let current = ethernet().map { "\($0.interface.name)/\($0.address)" }
    guard force || current != connection else { return }
    connection = current
    task?.cancel()
    guard !current.isEmpty else {
      notified = false
      return
    }
    task = Task { [weak self] in
      guard let self else { return }
      do {
        try await Task.sleep(for: .seconds(2))
        try await authenticate()
      } catch is CancellationError {
        // Disconnects and newer events are ordinary cancellation, not failures.
      } catch {
        let failure = error as? Failure ?? .response
        logger.error("\(failure.message, privacy: .public)")
        if !notified {
          notified = true
          Notifications.failure(failure.message)
        }
      }
    }
  }

  private func authenticate() async throws {
    let delays: [Duration] = [.seconds(5), .seconds(15)]
    for attempt in 0...delays.count {
      do {
        var unavailable = false
        for candidate in ethernet() {
          try Task.checkCancellation()
          let portal = Portal(transport: HTTPClient(ethernet: candidate))
          switch try await portal.status() {
          case .offline(let address):
            guard address == candidate.address else { throw Failure.addressChanged }
            try await portal.login(credentials: CredentialStore.load(), address: address)
            logger.notice("校园网登录成功")
            notified = false
            return
          case .online:
            notified = false
            return
          case .foreignNetwork: break
          case .unavailable: unavailable = true
          }
        }
        // A missing portal is normal off campus; retry briefly, then stay quiet.
        if !unavailable {
          notified = false
          return
        }
        if attempt == delays.count { return }
      } catch let failure as Failure {
        guard failure.retryable, attempt < delays.count else { throw failure }
      }
      try await Task.sleep(for: delays[attempt])
    }
  }
}
