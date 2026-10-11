import AppKit
import CoreServices
import Foundation
import Network
import SystemConfiguration

@main
enum Bitsrun {
  @MainActor
  static func main() {
    do {
      switch Array(CommandLine.arguments.dropFirst()) {
      case [], ["help"], ["--help"], ["-h"]:
        print(
          """
          bitsrun — 原生、事件驱动的北理工有线校园网登录

          bitsrun install     从 .env 导入钥匙串并安装后台服务
          bitsrun install --env FILE  从本地凭据文件导入钥匙串
          bitsrun uninstall   卸载后台服务，保留钥匙串凭据
          bitsrun run         前台运行（用于调试）
          bitsrun check       实际检测有线网与校园网认证状态
          """)
      case ["install"]:
        try Installation.install()
      case let arguments
      where arguments.count == 3 && Array(arguments.prefix(2)) == ["install", "--env"]:
        try Installation.install(env: URL(fileURLWithPath: arguments[2]).standardizedFileURL)
      case let arguments where arguments.count == 2 && arguments[0] == "configure":
        guard Bundle.main.bundleIdentifier == Installation.label else {
          throw Failure.credentials
        }
        try CredentialStore.save(Credentials.read(URL(fileURLWithPath: arguments[1])))
        Task {
          await Notifications.authorize()
          exit(0)
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.run()
      case ["uninstall"]:
        try Installation.uninstall()
      case ["check"]:
        Task {
          do {
            try await check()
            exit(0)
          } catch {
            report(error)
            exit(1)
          }
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.run()
      case ["run"]:
        let service = Service()
        try service.start()
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.run()
        service.stop()
      default:
        print("用法：bitsrun install | uninstall | run | check")
        exit(2)
      }
    } catch {
      report(error)
      exit(1)
    }
  }

  private static func report(_ error: any Error) {
    let message = (error as? Failure)?.message ?? "操作失败：\(error.localizedDescription)"
    FileHandle.standardError.write(Data((message + "\n").utf8))
  }

  @MainActor
  private static func check() async throws {
    let monitor = NWPathMonitor(requiredInterfaceType: .wiredEthernet)
    defer { monitor.cancel() }
    let path = await withCheckedContinuation { continuation in
      monitor.pathUpdateHandler = { path in
        monitor.pathUpdateHandler = nil
        continuation.resume(returning: path)
      }
      monitor.start(queue: .main)
    }
    let store = SCDynamicStoreCreate(nil, "bitsrun-check" as CFString, nil, nil)
    let candidates = Ethernet.connected(path.availableInterfaces, store: store)
    guard !candidates.isEmpty else {
      print("没有已取得 IPv4 的有线网卡；自动登录会保持静默。")
      return
    }
    for candidate in candidates {
      let portal = Portal(transport: HTTPClient(ethernet: candidate))
      let prefix = "\(candidate.interface.name)（\(candidate.address)）："
      switch try await portal.status() {
      case .online: print(prefix + "北理工校园网，已登录。")
      case .offline: print(prefix + "北理工校园网，未登录；运行 install 配置自动登录。")
      case .foreignNetwork: print(prefix + "不是北理工认证页面。")
      case .unavailable: print(prefix + "无法访问校园网认证服务。")
      }
    }
  }
}

// Installation changes user-owned files only, and never contacts the portal.
// Configure via the installed binary so keychain access belongs to the service.
@MainActor
private enum Installation {
  static let label = "local.bitsrun.auto"
  private static let files = FileManager.default
  private static let library = files.homeDirectoryForCurrentUser.appendingPathComponent("Library")
  private static let support = library.appendingPathComponent("Application Support/bitsrun")
  private static let app = support.appendingPathComponent("Bitsrun.app")
  private static let binary = app.appendingPathComponent("Contents/MacOS/bitsrun")
  private static let plist = library.appendingPathComponent("LaunchAgents/\(label).plist")
  private static let domain = "gui/\(getuid())"

  static func install(env: URL = URL(fileURLWithPath: ".env").standardizedFileURL) throws {
    _ = try Credentials.read(env)
    let source = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    if source == binary {
      try activate(env: env)
      return
    }
    let staging = support.appendingPathComponent("\(UUID().uuidString).app")
    let backup = support.appendingPathComponent("\(UUID().uuidString).app")
    try files.createDirectory(
      at: staging.appendingPathComponent("Contents/MacOS"),
      withIntermediateDirectories: true)
    defer { try? files.removeItem(at: staging) }
    let stagedBinary = staging.appendingPathComponent("Contents/MacOS/bitsrun")
    try files.copyItem(at: source, to: stagedBinary)
    try propertyList([
      "CFBundleIdentifier": label, "CFBundleName": "Bitsrun",
      "CFBundleDisplayName": "校园网自动登录", "CFBundleExecutable": "bitsrun",
      "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
      "LSUIElement": true, "LSMinimumSystemVersion": "13.0",
    ]).write(to: staging.appendingPathComponent("Contents/Info.plist"), options: .atomic)
    try execute(
      "/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", label, staging.path])
    // Signing is deterministic: an unchanged build keeps its keychain identity.
    if files.contentsEqual(atPath: stagedBinary.path, andPath: binary.path),
      files.contentsEqual(
        atPath: staging.appendingPathComponent("Contents/Info.plist").path,
        andPath: app.appendingPathComponent("Contents/Info.plist").path)
    {
      try activate(env: env)
      return
    }
    let previousPlist = try? Data(contentsOf: plist)
    let wasRunning =
      (try? execute("/bin/launchctl", ["print", "\(domain)/\(label)"], quiet: true)) != nil
    var replaced = false
    bootout()
    do {
      if files.fileExists(atPath: app.path) { try files.moveItem(at: app, to: backup) }
      try files.moveItem(at: staging, to: app)
      replaced = true
      _ = LSRegisterURL(app as CFURL, true)
      try execute(binary.path, ["configure", env.path])
      try files.createDirectory(
        at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
      let data = try propertyList([
        "Label": label, "ProgramArguments": [binary.path, "run"],
        "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 15,
        "ProcessType": "Background",
      ])
      try data.write(to: plist, options: .atomic)
      try execute("/bin/launchctl", ["bootstrap", domain, plist.path])
    } catch {
      let installationError = error
      do {
        bootout()
        if replaced { try files.removeItem(at: app) }
        if files.fileExists(atPath: backup.path) { try files.moveItem(at: backup, to: app) }
        if let previousPlist {
          try previousPlist.write(to: plist, options: .atomic)
        } else if files.fileExists(atPath: plist.path) {
          try files.removeItem(at: plist)
        }
        if wasRunning { try execute("/bin/launchctl", ["bootstrap", domain, plist.path]) }
      } catch {
        throw NSError(
          domain: label, code: 1,
          userInfo: [
            NSLocalizedDescriptionKey: "安装回滚失败；原程序如仍存在，保留在 \(backup.path)。"
          ])
      }
      throw installationError
    }
    try? files.removeItem(at: backup)
    print("已启用；插线、网络变化或唤醒时自动检查。")
  }

  private static func activate(env: URL) throws {
    try execute(binary.path, ["configure", env.path])
    if (try? execute("/bin/launchctl", ["print", "\(domain)/\(label)"], quiet: true)) == nil {
      try execute("/bin/launchctl", ["bootstrap", domain, plist.path])
    } else {
      try execute("/bin/launchctl", ["kickstart", "-k", "\(domain)/\(label)"])
    }
    print("已启用；程序未变更，无需替换应用。")
  }

  static func uninstall() throws {
    bootout()
    if files.fileExists(atPath: plist.path) { try files.removeItem(at: plist) }
    if files.fileExists(atPath: app.path) { try files.removeItem(at: app) }
    print("服务已卸载；钥匙串凭据保留，可在“钥匙串访问”中搜索 bitsrun 删除。")
  }

  private static func bootout() {
    try? execute("/bin/launchctl", ["bootout", "\(domain)/\(label)"], quiet: true)
  }

  private static func propertyList(_ values: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
  }

  private static func execute(_ executable: String, _ arguments: [String], quiet: Bool = false)
    throws
  {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if quiet {
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
    }
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw NSError(
        domain: label, code: Int(process.terminationStatus),
        userInfo: [
          NSLocalizedDescriptionKey:
            "\(URL(fileURLWithPath: executable).lastPathComponent) 执行失败（\(process.terminationStatus)）。"
        ])
    }
  }
}
