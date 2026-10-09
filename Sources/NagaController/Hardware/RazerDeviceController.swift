import Foundation

@MainActor
final class RazerDeviceController {
    static let shared = RazerDeviceController()
    static let didUpdateNotification = Notification.Name("RazerDeviceControllerDidUpdate")
    private(set) var isConnected = false
    private(set) var isBusy = false
    private(set) var dpiX: Int?
    private(set) var dpiY: Int?
    private(set) var pollingRate: Int?
    private(set) var batteryLevel: Int?
    private(set) var scrollAcceleration: Bool?
    private(set) var smartReel: Bool?
    private(set) var lighting: [RazerLightZone: RazerLightState]?
    private(set) var driverModeEnabled = false
    private(set) var recoveryPending = false
    private(set) var statusMessage = "Connect the USB receiver and press Refresh."

    private let queue = DispatchQueue(label: "NagaController.hardware", qos: .userInitiated)
    private let worker = Worker()
    private var shuttingDown = false

    // Construction does not open the receiver or change its settings.
    private init() {}
    func refresh() { submit(.refresh) }
    func setDPI(x: Int, y: Int) { submit(.dpi(x, y)) }
    func setPollingRate(_ hz: Int) { submit(.polling(hz)) }
    func setScrollAcceleration(_ on: Bool) { submit(.scrollAcceleration(on)) }
    func setSmartReel(_ on: Bool) { submit(.smartReel(on)) }
    func setLighting(zones: [RazerLightZone], effect: RazerLightEffect, rgb: [Int], brightness: Int) {
        submit(.lighting(zones, effect, rgb, brightness))
    }
    func setDriverModeEnabled(_ enabled: Bool) {
        guard !OnboardProfileStore.isActive else { return }
        submit(.mode(enabled))
    }
    func saveOnboard(_ plan: OnboardProfilePlan) {
        guard !isBusy, !shuttingDown, plan.isSupported else { return }
        EventTapManager.shared.stop()
        submit(.onboard(plan))
    }
    func restoreOnboard() {
        guard !isBusy, !shuttingDown else { return }
        EventTapManager.shared.stop()
        submit(.restoreOnboard)
    }

    // The app must defer termination until this callback. Failed restores retain
    // the journal for an explicit recovery attempt on a later launch.
    func restoreOriginalMode(completion: @escaping @MainActor @Sendable () -> Void = {}) {
        shuttingDown = true
        submit(.restore, completion: completion)
    }
    // Manual recovery does not stop future operations, unlike the shutdown hook.
    func recoverOriginalMode() { submit(.recover) }

    private enum Operation: Sendable {
        case refresh, dpi(Int, Int), polling(Int), scrollAcceleration(Bool), smartReel(Bool),
             lighting([RazerLightZone], RazerLightEffect, [Int], Int), mode(Bool), restore, recover, onboard(OnboardProfilePlan), restoreOnboard
    }
    private func submit(_ operation: Operation, completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard !shuttingDown || completion != nil else { return }
        // Do not enqueue stale slider writes. Shutdown restoration is the one
        // operation allowed behind an in-flight request.
        guard !isBusy || completion != nil else { return }
        isBusy = true
        statusMessage = "Talking to the mouse…"
        notify()
        let worker = worker
        queue.async { [weak self] in
            let outcome = worker.perform(operation)
            DispatchQueue.main.async {
                guard let self else { completion?(); return }
                self.isBusy = false
                self.isConnected = outcome.connected
                self.dpiX = outcome.snapshot?.dpiX
                self.dpiY = outcome.snapshot?.dpiY
                self.pollingRate = outcome.snapshot?.pollingRate
                self.batteryLevel = outcome.snapshot?.batteryLevel
                self.scrollAcceleration = outcome.snapshot?.scrollAcceleration
                self.smartReel = outcome.snapshot?.smartReel
                self.lighting = outcome.snapshot?.lighting
                self.driverModeEnabled = outcome.snapshot?.mode == 3
                self.recoveryPending = outcome.recoveryPending
                self.statusMessage = outcome.message
                switch operation {
                case .onboard, .restoreOnboard:
                    if !self.shuttingDown, PermissionManager.shared.hasAccessibilityPermission(), PermissionManager.shared.hasInputMonitoringPermission() {
                        EventTapManager.shared.start(listenOnly: !ConfigManager.shared.getRemappingEnabled())
                    }
                default: break
                }
                self.notify()
                completion?()
            }
        }
    }
    private func notify() { NotificationCenter.default.post(name: Self.didUpdateNotification, object: self) }

    // All worker state is confined to queue. Never capture the controller in
    // transport callbacks or block the main queue waiting for hardware.
    private final class Worker: @unchecked Sendable {
        private struct Recovery: Codable {
            let identity: String
            let originalMode: UInt8
        }
        fileprivate struct Outcome {
            let connected: Bool
            let snapshot: RazerHardwareSnapshot?
            let message: String
            let recoveryPending: Bool
        }
        private let journalURL = DataFolder.file("driver-mode-recovery.json")
        private var modeChangedThisSession = false

        fileprivate func perform(_ operation: Operation) -> Outcome {
            // Shutdown without an outstanding mode change requires no USB I/O.
            if case .restore = operation, !modeChangedThisSession {
                return Outcome(connected: false, snapshot: nil, message: "No mode to restore.",
                               recoveryPending: FileManager.default.fileExists(atPath: journalURL.path))
            }
            let transport = MacRazerUSBTransport()
            var connected = false
            defer { transport.close() }
            do {
                // Validate user input before opening any device.
                if case .dpi(let x, let y) = operation { _ = try RazerCommand.setDPI(x: x, y: y) }
                if case .polling(let hz) = operation { _ = try RazerCommand.setPolling(hz) }
                if case .lighting(let zones, let effect, let rgb, let brightness) = operation {
                    guard rgb.count == 3, !zones.isEmpty else { throw RazerHardwareError.invalidValue("Choose a zone and a color.") }
                    for zone in zones { _ = try RazerCommand.setLighting(zone, effect: effect, r: rgb[0], g: rgb[1], b: rgb[2], brightness: brightness) }
                }
                try transport.open()
                connected = true
                let session = RazerHardwareSession(transport: transport)
                var onboardMessage: String?
                if !transport.supportsV2OnlyFeatures {
                    switch operation {
                    case .mode:
                        throw RazerHardwareError.invalidValue("Driver mode is only verified on the Naga V2 HyperSpeed receiver.")
                    default: break
                    }
                }
                if !RazerOnboardBindings.isV3Pro(identity: transport.identity) {
                    switch operation {
                    case .scrollAcceleration, .smartReel, .lighting:
                        throw RazerHardwareError.invalidValue("Scroll and lighting settings are only available on the Naga V3 Pro.")
                    default: break
                    }
                }
                switch operation {
                case .refresh: break
                case .dpi(let x, let y): try session.setDPI(x: x, y: y)
                case .polling(let hz): try session.setPolling(hz)
                case .scrollAcceleration(let on): try session.setScrollAcceleration(on)
                case .smartReel(let on): try session.setSmartReel(on)
                case .lighting(let zones, let effect, let rgb, let brightness):
                    try session.setLighting(zones, effect: effect, r: rgb[0], g: rgb[1], b: rgb[2], brightness: brightness)
                case .onboard(let plan):
                    guard !FileManager.default.fileExists(atPath: journalURL.path) else {
                        throw RazerHardwareError.invalidValue("Restore the original driver mode first.")
                    }
                    let skipped = try OnboardProfileStore.save(plan, session: session, identity: transport.identity)
                    let note = skipped.isEmpty ? "" : " Not on this mouse, skipped: \(skipped.map(buttonName).joined(separator: ", "))."
                    let layerNote = OnboardProfileStore.skipsHypershift(plan, identity: transport.identity)
                        ? " Hypershift layer not saved: not verified on this mouse." : ""
                    onboardMessage = "Profile \(plan.name) saved to the mouse. It keeps working after Quit.\(note)\(layerNote)"
                case .restoreOnboard:
                    try OnboardProfileStore.restore(session: session, identity: transport.identity)
                    onboardMessage = "Previous assignments restored. Software remapping is available."
                case .mode(let enabled):
                    let current = try session.readMode()
                    let target: UInt8 = enabled ? 3 : 0
                    if current != target {
                        if FileManager.default.fileExists(atPath: journalURL.path) {
                            let saved = try readRecovery()
                            guard saved.identity == transport.identity else {
                                throw RazerHardwareError.transport("A restore is pending for another receiver. No mode was changed.")
                            }
                            guard modeChangedThisSession else {
                                throw RazerHardwareError.transport("Explicitly restore the previous session's mode before changing it.")
                            }
                        } else {
                            // Atomic journal write must succeed BEFORE mode SET.
                            try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                            let data = try JSONEncoder().encode(Recovery(identity: transport.identity, originalMode: current))
                            try data.write(to: journalURL, options: .atomic)
                        }
                        // A timeout can follow a successful device write, so
                        // restoration is required even if readback fails.
                        modeChangedThisSession = true
                        try session.setMode(target)
                    }
                case .restore, .recover:
                    let saved = try readRecovery()
                    guard saved.identity == transport.identity else {
                        throw RazerHardwareError.transport("Reconnect the receiver to its original USB port to restore the mode.")
                    }
                    if try session.readMode() != saved.originalMode { try session.setMode(saved.originalMode) }
                    try FileManager.default.removeItem(at: journalURL)
                    modeChangedThisSession = false
                }
                let snapshot = try session.readSnapshot()
                let recoveryPending = FileManager.default.fileExists(atPath: journalURL.path)
                let message = recoveryPending
                        ? (modeChangedThisSession
                            ? "Values read. The original mode will be restored when you quit."
                            : "A restore is pending from a previous session. Use Restore Original Mode.")
                        : "Hardware values read over USB."
                return Outcome(connected: true, snapshot: snapshot,
                               message: ([onboardMessage ?? message] + snapshot.warnings).joined(separator: "\n"),
                               recoveryPending: recoveryPending)
            } catch {
                return Outcome(connected: connected, snapshot: nil, message: error.localizedDescription,
                               recoveryPending: FileManager.default.fileExists(atPath: journalURL.path))
            }
        }
        private func readRecovery() throws -> Recovery {
            let saved = try JSONDecoder().decode(Recovery.self, from: Data(contentsOf: journalURL))
            guard saved.originalMode == 0 || saved.originalMode == 3 else {
                throw RazerHardwareError.invalidValue("Invalid restore record.")
            }
            return saved
        }
    }
}
