import AppKit
import Combine
import CoreGraphics
import IOKit
import Network

/// 合盖后只在外部显示器仍工作时继续采集, 系统睡眠始终优先
@MainActor
final class SystemConnectionGate {
    private var observations = Set<AnyCancellable>()
    private let network = NWPathMonitor()
    private var notificationPort: IONotificationPortRef?
    private var rootDomain: io_service_t = 0
    private var interest: io_object_t = 0
    private var isSleeping = false
    private var areDisplaysSleeping = false
    private var hasNetwork = false
    private var lastAllowed: Bool?
    private var lastLocalAllowed: Bool?
    private var onChange: ((Bool, Bool) -> Void)?

    func start(onChange: @escaping (Bool, Bool) -> Void) {
        self.onChange = onChange
        let center = NSWorkspace.shared.notificationCenter
        center.publisher(for: NSWorkspace.willSleepNotification).sink { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isSleeping = true
                // DarkWake 可能先于显示器唤醒, 不能仅凭旧显示列表恢复合盖采集
                self?.areDisplaysSleeping = true
                self?.publish()
            }
        }.store(in: &observations)
        center.publisher(for: NSWorkspace.screensDidSleepNotification).sink { [weak self] _ in
            MainActor.assumeIsolated {
                self?.areDisplaysSleeping = true
                self?.publish()
            }
        }.store(in: &observations)
        center.publisher(for: NSWorkspace.screensDidWakeNotification).sink { [weak self] _ in
            MainActor.assumeIsolated {
                self?.areDisplaysSleeping = false
                self?.publish()
            }
        }.store(in: &observations)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification).sink { [weak self] _ in
            MainActor.assumeIsolated {
                self?.publish()
            }
        }.store(in: &observations)
        center.publisher(for: NSWorkspace.didWakeNotification).sink { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isSleeping = false
                self?.publish()
            }
        }.store(in: &observations)
        network.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.hasNetwork = path.status == .satisfied
                self?.publish()
            }
        }
        network.start(queue: DispatchQueue(label: "CodexBar.connection-path", qos: .utility))
        rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        notificationPort = IONotificationPortCreate(kIOMainPortDefault)
        if let port = notificationPort, rootDomain != 0 {
            IONotificationPortSetDispatchQueue(port, .main)
            IOServiceAddInterestNotification(port, rootDomain, kIOGeneralInterest, { context, _, _, _ in
                guard let context else { return }
                MainActor.assumeIsolated {
                    Unmanaged<SystemConnectionGate>.fromOpaque(context).takeUnretainedValue().publish()
                }
            }, Unmanaged.passUnretained(self).toOpaque(), &interest)
        }
        publish()
    }

    func stop() {
        network.cancel()
        observations.removeAll()
        if interest != 0 {
            IOObjectRelease(interest)
            interest = 0
        }
        if rootDomain != 0 {
            IOObjectRelease(rootDomain)
            rootDomain = 0
        }
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
        }
        notificationPort = nil
        onChange = nil
    }

    private func publish() {
        let closed = rootDomain != 0
            ? (IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.boolValue ?? false
            : false
        let localAllowed = Self.allowsLocalActivity(
            isSleeping: isSleeping,
            lidClosed: closed,
            areDisplaysSleeping: areDisplaysSleeping,
            hasAwakeExternalDisplay: closed && !isSleeping && !areDisplaysSleeping && Self.hasAwakeExternalDisplay()
        )
        let allowed = localAllowed && hasNetwork
        guard allowed != lastAllowed || localAllowed != lastLocalAllowed else { return }
        lastAllowed = allowed
        lastLocalAllowed = localAllowed
        onChange?(allowed, localAllowed)
    }

    nonisolated static func allowsLocalActivity(
        isSleeping: Bool,
        lidClosed: Bool,
        areDisplaysSleeping: Bool,
        hasAwakeExternalDisplay: Bool
    ) -> Bool {
        !isSleeping && (!lidClosed || (!areDisplaysSleeping && hasAwakeExternalDisplay))
    }

    nonisolated static func isAwakeExternalDisplay(
        isBuiltin: Bool,
        isActive: Bool,
        isAsleep: Bool,
        isMirrored: Bool
    ) -> Bool {
        !isBuiltin && !isAsleep && (isActive || isMirrored)
    }

    private static func hasAwakeExternalDisplay() -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return false }
        // 合盖后内屏可能从列表消失, 硬件镜像副屏也可能不标为 active
        // 在线列表包含物理和虚拟显示器, 仅连接或已熄灭的显示器不构成例外
        return displays.prefix(Int(count)).contains { display in
            Self.isAwakeExternalDisplay(
                isBuiltin: CGDisplayIsBuiltin(display) != 0,
                isActive: CGDisplayIsActive(display) != 0,
                isAsleep: CGDisplayIsAsleep(display) != 0,
                isMirrored: CGDisplayIsInMirrorSet(display) != 0
            )
        }
    }
}
