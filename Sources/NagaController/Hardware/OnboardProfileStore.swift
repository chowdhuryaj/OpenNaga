import Foundation

// Invoked only by explicit save/restore operations on the hardware worker queue.
enum OnboardProfileStore {
    struct State: Codable {
        let identity: String
        let original: [[UInt8]]
        // Hypershift layer (V3 Pro only). Absent in journals written before 2026-10-07.
        var hypershift: [[UInt8]]?
        var name: String
        var pending: Bool
    }
    static var url: URL { DataFolder.file("onboard-profile.json") }
    // A pending or unreadable journal also blocks software interception after a crash.
    static var isActive: Bool { FileManager.default.fileExists(atPath: url.path) }
    static var savedName: String? {
        guard let state = try? load(from: url), !state.pending else { return nil }
        return state.name
    }

    // The backup holds this model's original assignments, so it follows the
    // receiver model (vendor:product) rather than the USB port it was saved on.
    // The V3 Pro cable (00e7) and dongle (00e8) reach the same mouse memory.
    static func sameReceiver(_ a: String, _ b: String) -> Bool {
        func model(_ s: String) -> [Substring] { s.split(separator: ":").prefix(2).map { $0 == "00e8" ? "00e7" : $0 } }
        return model(a) == model(b)
    }

    static func load(from url: URL) throws -> State {
        let state = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
        for (layer, list) in [(UInt8(0), state.original), (1, state.hypershift)] {
            guard let list else { continue }
            guard !state.identity.isEmpty, list.count == RazerOnboardBindings.controlCount(identity: state.identity) else {
                throw RazerHardwareError.malformed("Incomplete mouse backup.")
            }
            var ids = Set<UInt8>()
            for bytes in list {
                guard bytes.count == 10 else { throw RazerHardwareError.malformed("Invalid mouse backup.") }
                _ = try RazerOnboardBinding(bytes: bytes, profile: 1, buttonID: bytes[1], layer: layer)
                guard ids.insert(bytes[1]).inserted else { throw RazerHardwareError.malformed("Duplicate button in the backup.") }
            }
        }
        return state
    }

    /// True when `save` ignores the plan's Hypershift layer (not verified on this mouse).
    static func skipsHypershift(_ plan: OnboardProfilePlan, identity: String) -> Bool {
        !plan.hypershiftFunctions.isEmpty && !RazerOnboardBindings.hasHypershift(identity: identity)
    }

    /// Returns the logical buttons skipped because this mouse does not list them.
    /// The Hypershift layer is read and written only on the V3 Pro (see `skipsHypershift`).
    @discardableResult
    static func save(_ plan: OnboardProfilePlan, session: RazerHardwareSession, identity: String, at url: URL = url) throws -> [Int] {
        guard plan.isSupported else { throw RazerHardwareError.invalidValue(plan.issues.joined(separator: "\n")) }
        guard try session.readMode() == 0 else { throw RazerHardwareError.invalidValue("Turn off driver mode before saving to the mouse.") }
        let previousData = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        let previous = previousData == nil ? nil : try load(from: url)
        guard previous.map({ sameReceiver($0.identity, identity) && !$0.pending }) ?? true else {
            throw RazerHardwareError.invalidValue("Restore the pending backup with the original receiver first.")
        }
        let before = try RazerOnboardBindings.read(session: session, profile: 1).map(\.bytes)
        guard before.count == RazerOnboardBindings.controlCount(identity: identity) else {
            throw RazerHardwareError.malformed("Unexpected button layout.")
        }
        // Back up layer 1 before the first write of either layer.
        let hyperBefore = RazerOnboardBindings.hasHypershift(identity: identity)
            ? try RazerOnboardBindings.read(session: session, profile: 1, layer: 1).map(\.bytes) : nil
        let original = previous?.original ?? before
        // A journal from before Hypershift support never wrote layer 1, so the fresh read is the original.
        let hyperOriginal = hyperBefore.map { previous?.hypershift ?? $0 }
        let present = Set(before.map { $0[1] })
        // Only the V3 Pro extras (20 to 22) may be missing; targets come from the mouse's own list.
        let skipped = OnboardProfilePlan.buttonIDs.filter { plan.functions[$0.value] != nil && !present.contains($0.value) }.keys.sorted()
        guard Set(original.map { $0[1] }) == present, hyperOriginal.map({ Set($0.map { $0[1] }) == present }) ?? true,
              skipped.allSatisfy({ $0 >= 20 }) else {
            throw RazerHardwareError.malformed("The backup or profile does not match the mouse buttons.")
        }
        // Unset buttons go back to the backup; an untouched Hypershift entry is never written.
        func targets(_ list: [[UInt8]], _ functions: [UInt8: [UInt8]], layer: UInt8) -> [[UInt8]] {
            list.map { bytes in functions[bytes[1]].map { [1, bytes[1], layer] + $0 } ?? bytes }
        }
        let normal = targets(original, plan.functions, layer: 0)
        let hyper = hyperOriginal.map { targets($0, plan.hypershiftFunctions, layer: 1) } ?? []
        let beforeByID = [before, hyperBefore ?? []].map { Dictionary(uniqueKeysWithValues: $0.map { ($0[1], $0) }) }
        // Layer 0 first, then layer 1; unchanged controls (0x6a included) are never rewritten.
        let changed = [normal, hyper].enumerated().flatMap { layer, list in
            list.filter { !same(beforeByID[layer][$0[1]], $0) }.map { ($0, UInt8(layer)) }
        }
        var state = State(identity: previous?.identity ?? identity, original: original, hypershift: hyperOriginal, name: plan.name, pending: true)
        try persist(state, at: url)
        do {
            for (target, layer) in changed { try write(target, layer: layer, session: session) }
            // Also verify the active mirror, including an unchanged saved profile.
            for target in normal { try verify(target, profile: 0, layer: 0, session: session) }
            // An untouched layer 1 entry (flag 00) that this save did not write may track the
            // normal layer live (unverified), so only written or previously written ones are checked.
            let written = Set(changed.filter { $0.1 == 1 }.map { $0.0[1] })
            for target in hyper where written.contains(target[1]) || beforeByID[1][target[1]]?[2] == 1 {
                try verify(target, profile: 0, layer: 1, session: session)
            }
            state.pending = false
            try persist(state, at: url)
            return skipped
        } catch {
            let failure = error
            do {
                // Include the uncertain write: an ACK timeout can follow a successful SET.
                for (target, layer) in changed.reversed() {
                    if let old = beforeByID[Int(layer)][target[1]] { try write(old, layer: layer, session: session) }
                }
                if let previousData { try previousData.write(to: url, options: .atomic) }
                else { try FileManager.default.removeItem(at: url) }
            } catch {
                throw RazerHardwareError.transport("Save interrupted. The backup was kept; use Restore Previous Assignments. \(error.localizedDescription)")
            }
            throw failure
        }
    }

    static func restore(session: RazerHardwareSession, identity: String, at url: URL = url) throws {
        var state = try load(from: url)
        guard sameReceiver(state.identity, identity) else { throw RazerHardwareError.invalidValue("Connect the receiver that was used for the save.") }
        guard try session.readMode() == 0 else { throw RazerHardwareError.invalidValue("Turn off driver mode before restoring.") }
        let current = try RazerOnboardBindings.read(session: session, profile: 1).map(\.bytes)
        let hyperCurrent = state.hypershift == nil ? [] : try RazerOnboardBindings.read(session: session, profile: 1, layer: 1).map(\.bytes)
        guard Set(current.map { $0[1] }) == Set(state.original.map { $0[1] }),
              state.hypershift.map({ Set($0.map { $0[1] }) == Set(hyperCurrent.map { $0[1] }) }) ?? true else {
            throw RazerHardwareError.malformed("The backup does not match the mouse controls.")
        }
        state.pending = true
        try persist(state, at: url)
        for (layer, originals, now) in [(UInt8(0), state.original, current), (1, state.hypershift ?? [], hyperCurrent)] {
            let currentByID = Dictionary(uniqueKeysWithValues: now.map { ($0[1], $0) })
            for original in originals {
                if !same(currentByID[original[1]], original) { try write(original, layer: layer, session: session) }
                try verify(original, profile: 0, layer: layer, session: session)
            }
        }
        try FileManager.default.removeItem(at: url)
    }

    private static func persist(_ state: State, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }

    // Byte 2 is ignored: in a response it is a per-control flag (01 once the control's
    // Hypershift entry was written), in both layers.
    // A restored Hypershift entry reads 01 afterwards and cannot be reset to untouched,
    // so comparisons check bytes 0, 1 and 3 to 9.
    static func same(_ a: [UInt8]?, _ b: [UInt8]) -> Bool {
        guard let a, a.count == b.count else { return false }
        return a.indices.allSatisfy { $0 == 2 || a[$0] == b[$0] }
    }

    /// Writes always send byte 2 = layer, whatever the backup's stored flag was.
    static func write(_ bytes: [UInt8], layer: UInt8 = 0, session: RazerHardwareSession) throws {
        guard bytes.count == 10 else { throw RazerHardwareError.invalidValue("Invalid assignment to write.") }
        _ = try RazerOnboardBinding(bytes: bytes, profile: 1, buttonID: bytes[1], layer: layer)
        var arguments = bytes
        arguments[2] = layer
        let command = RazerCommand(transaction: 0x1f, commandClass: 2, id: 0x0c, arguments: arguments)
        _ = try session.execute(command)
        try verify(arguments, profile: 1, layer: layer, session: session)
    }

    private static func verify(_ bytes: [UInt8], profile: UInt8, layer: UInt8, session: RazerHardwareSession) throws {
        var expected = bytes
        expected[0] = profile
        let actual = try session.execute(RazerOnboardBindings.readCommand(profile: profile, buttonID: bytes[1], layer: layer))
        guard actual.count == 10, actual[2] <= 1, same(actual, expected) else { throw RazerHardwareError.readback }
    }
}
