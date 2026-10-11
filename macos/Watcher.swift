import AppKit
import Foundation
import SystemConfiguration

// All scheduler state lives on the main run loop. Only the child runs off-main.
final class Watcher {
  var pending: DispatchWorkItem?
  var generation = 0
  var running = false
  var dirty = false
  var lastStarted = Date.distantPast
  var failures = 0
  var notified = false
  let executable: String

  init(_ executable: String) {
    self.executable = executable
  }

  func event() {
    generation += 1
    failures = 0
    pending?.cancel()
    if running {
      dirty = true
      return
    }
    schedule(after: max(2, 15 - Date().timeIntervalSince(lastStarted)))
  }

  func schedule(after delay: Double) {
    let current = generation
    let task = DispatchWorkItem { [weak self] in
      guard let self, self.generation == current else { return }
      self.run(current)
    }
    pending = task
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
  }

  func run(_ current: Int) {
    running = true
    lastStarted = Date()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    // Bound each check, including any stalled OS command.
    DispatchQueue.global().async {
      var code: Int32 = 1
      do {
        try process.run()
        let timeout = DispatchWorkItem {
          if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: timeout)
        process.waitUntilExit()
        timeout.cancel()
        code = process.terminationStatus
      } catch {}
      let result = code
      DispatchQueue.main.async {
        self.running = false
        if self.dirty || current != self.generation {
          self.dirty = false
          self.schedule(after: max(2, 15 - Date().timeIntervalSince(self.lastStarted)))
          return
        }
        if result == 0 {
          self.notified = false
          return
        }
        self.failures += 1
        if result == 1 && self.failures < 3 {
          self.schedule(after: self.failures == 1 ? 5 : 15)
        } else if !self.notified {
          self.notified = true
          let script = NSAppleScript(source: "display notification \"校园网自动登录失败，请检查配置或日志\" with title \"bitsrun\"")
          script?.executeAndReturnError(nil)
        }
      }
    }
  }
}

if CommandLine.arguments.count != 2 {
  fputs("Usage: watcher /absolute/path/to/bitsrun-auto\n", stderr)
  exit(2)
}
let watcher = Watcher(CommandLine.arguments[1])
let callback: SCDynamicStoreCallBack = { _, _, _ in watcher.event() }
guard let store = SCDynamicStoreCreate(nil, "bitsrun" as CFString, callback, nil),
  SCDynamicStoreSetNotificationKeys(store, ["State:/Network/Global/IPv4"] as CFArray,
    ["State:/Network/Interface/.*/Link", "State:/Network/Interface/.*/IPv4"] as CFArray),
  let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0)
else { exit(1) }
CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
let wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
  forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
) { _ in watcher.event() }
watcher.event()
RunLoop.main.run()
