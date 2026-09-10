import AppKit
import Combine
import IOKit
import Network

/// 合盖状态独立于系统睡眠, 防睡眠开启时也必须停止后台联网
@MainActor
final class SystemConnectionGate {
    private var observations = Set<AnyCancellable>()
    private let network = NWPathMonitor()
    private var notificationPort: IONotificationPortRef?
    private var rootDomain: io_service_t = 0
    private var interest: io_object_t = 0
    private var isSleeping = false
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
        let allowed = Self.allowsConnection(isSleeping: isSleeping, lidClosed: closed, hasNetwork: hasNetwork)
        let localAllowed = !isSleeping && !closed
        guard allowed != lastAllowed || localAllowed != lastLocalAllowed else { return }
        lastAllowed = allowed
        lastLocalAllowed = localAllowed
        onChange?(allowed, localAllowed)
    }

    nonisolated static func allowsConnection(isSleeping: Bool, lidClosed: Bool, hasNetwork: Bool) -> Bool {
        !isSleeping && !lidClosed && hasNetwork
    }
}
