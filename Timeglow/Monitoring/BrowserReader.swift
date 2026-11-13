import AppKit
import Carbon
import ScriptingBridge

enum BrowserPermission: Equatable, Sendable {
    case notRequested, allowed, denied, notRunning, unavailable(Int32)

    var label: String {
        switch self {
        case .notRequested: return "尚未授权"
        case .allowed: return "已授权"
        case .denied: return "未获授权，请在系统设置中允许"
        case .notRunning: return "请先打开浏览器"
        case .unavailable(let code): return "暂不可用（\(code)）"
        }
    }
}

struct BrowserContext: Sendable {
    var permission: BrowserPermission
    var domain: String?
    var isPrivate = false
}

@objc private protocol BrowserApplicationScripting {
    @objc optional func windows() -> SBElementArray
}

@objc private protocol BrowserObjectScripting {
    @objc optional var activeTab: SBObject { get }
    @objc optional var currentTab: SBObject { get }
    @objc optional var URL: String { get }
    @objc optional var mode: String { get }
}

extension SBApplication: BrowserApplicationScripting {}
extension SBObject: BrowserObjectScripting {}

/// All Apple Events run off the UI thread, to an existing process, with a bounded timeout.
final class BrowserReader: @unchecked Sendable {
    static let supported = ["com.apple.Safari": "Safari", "com.google.Chrome": "Google Chrome"]
    private let queue = DispatchQueue(label: "com.xiaofengchen.Timeglow.browser", qos: .utility)

    func requestPermission(pid: pid_t, completion: @escaping @Sendable (BrowserPermission) -> Void) {
        queue.async { completion(Self.permission(pid: pid, ask: true)) }
    }

    /// Refresh the displayed authorization state without reading a tab or prompting.
    func checkPermission(pid: pid_t, completion: @escaping @Sendable (BrowserPermission) -> Void) {
        queue.async { completion(Self.permission(pid: pid, ask: false)) }
    }

    func read(pid: pid_t, bundleID: String, completion: @escaping @Sendable (BrowserContext) -> Void) {
        queue.async {
            guard Self.supported[bundleID] != nil else { completion(.init(permission: .unavailable(-1708))); return }
            let permission = Self.permission(pid: pid, ask: false)
            guard permission == .allowed else { completion(.init(permission: permission)); return }
            guard let app = SBApplication(processIdentifier: pid), app.isRunning else {
                completion(.init(permission: .notRunning)); return
            }
            app.timeout = 120 // Apple Event timeout units are 1/60 second.
            app.sendMode = AESendMode(kAEWaitReply | kAENeverInteract)
            let scripting = app as BrowserApplicationScripting
            guard let windows = scripting.windows?(), let window = windows.firstObject as? SBObject else {
                completion(.init(permission: permission)); return
            }
            let windowContext = window as BrowserObjectScripting
            if bundleID == "com.google.Chrome", windowContext.mode == "incognito" {
                completion(.init(permission: permission, isPrivate: true)); return
            }
            let tab = bundleID == "com.apple.Safari" ? windowContext.currentTab : windowContext.activeTab
            let tabContext = tab.map { $0 as BrowserObjectScripting }
            completion(.init(permission: permission, domain: tabContext?.URL.flatMap(DomainRules.normalized)))
        }
    }

    private static func permission(pid: pid_t, ask: Bool) -> BrowserPermission {
        guard let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated else { return .notRunning }
        var target = AEAddressDesc(), processID = pid
        let created = AECreateDesc(DescType(typeKernelProcessID), &processID, MemoryLayout<pid_t>.size, &target)
        guard created == noErr else { return .unavailable(Int32(created)) }
        defer { AEDisposeDesc(&target) }
        let status = AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
        switch status {
        case noErr: return .allowed
        case -1744: return .notRequested
        case -1743: return .denied
        case -600: return .notRunning
        default: return .unavailable(status)
        }
    }
}
