import Foundation

// Wire facts from OpenRazer issue 2845 and OpenSnek USB_PROFILE_CRUD_SPEC.md.
// Independently verified on receiver 1532:00b4 on 2026-09-11. No foreign code copied.
// Naga V3 Pro cable 1532:00e7 (read 2026-10-07): same descriptors and bank layout, 33 controls.
// It echoes the requested list size, so it needs a 34-byte request to return the whole list.
// Profile 0 is the active view; profile 1 is the stored bank. Neither is changed here.
// Byte 2 selects the layer: 0 normal, 1 Hypershift (V3 Pro, read 2026-10-07). In a read
// response it is a per-control flag, not an echo: 01 once that control's Hypershift entry
// has been written, in the responses of both layers (0x40 read 01 01 in layer 0 and 1).
struct RazerOnboardBinding: Equatable, Codable {
    let bytes: [UInt8]
    var profile: UInt8 { bytes[0] }
    var buttonID: UInt8 { bytes[1] }

    init(bytes: [UInt8], profile: UInt8, buttonID: UInt8, layer: UInt8 = 0) throws {
        guard bytes.count == 10, bytes[0] == profile, bytes[1] == buttonID, bytes[2] <= 1 else {
            throw RazerHardwareError.malformed("Invalid hardware assignment or one that refers to another button.")
        }
        // Preserve every function byte, including unknown types. Factory keyboard
        // bindings use length 1 but still carry a usage in byte 6 on this receiver.
        self.bytes = bytes
    }
}

enum RazerOnboardBindings {
    static let getButtonIDs = getButtonIDs(size: 22)
    static func getButtonIDs(size: Int) -> RazerCommand {
        RazerCommand(transaction: 0x1f, commandClass: 2, id: 0x84, arguments: Array(repeating: 0, count: size))
    }

    /// Bindable controls per model: V2 HyperSpeed receiver 21, V3 Pro cable or dongle 33.
    static func controlCount(identity: String) -> Int {
        ["00e7", "00e8"].contains(identity.split(separator: ":").dropFirst().first ?? "") ? 33 : 21
    }
    /// The Hypershift layer is verified only on the V3 Pro (cable; the dongle reaches the same mouse).
    static func hasHypershift(identity: String) -> Bool { isV3Pro(identity: identity) }
    static func isV3Pro(identity: String) -> Bool { controlCount(identity: identity) == 33 }

    static func readCommand(profile: UInt8, buttonID: UInt8, layer: UInt8 = 0) throws -> RazerCommand {
        guard profile <= 1, layer <= 1 else {
            throw RazerHardwareError.invalidValue("Only the active and stored profiles are supported.")
        }
        return RazerCommand(transaction: 0x1f, commandClass: 2, id: 0x8c,
                            arguments: [profile, buttonID, layer, 0, 0, 0, 0, 0, 0, 0])
    }

    static func decodeButtonIDs(_ bytes: [UInt8]) throws -> [UInt8] {
        guard bytes.count >= 22, let count = bytes.first, count > 0, Int(count) < bytes.count else {
            throw RazerHardwareError.malformed("Invalid hardware button list.")
        }
        let ids = Array(bytes[1...Int(count)])
        guard !ids.contains(0), Set(ids).count == ids.count else {
            throw RazerHardwareError.malformed("Duplicate or incomplete hardware button list.")
        }
        return ids
    }

    static func read(session: RazerHardwareSession, profile: UInt8, layer: UInt8 = 0) throws -> [RazerOnboardBinding] {
        // Validate the bank before any USB traffic.
        _ = try readCommand(profile: profile, buttonID: 1, layer: layer)
        let count = controlCount(identity: session.transport.identity)
        let ids = try decodeButtonIDs(session.execute(getButtonIDs(size: count == 21 ? 22 : count + 1)))
        return try ids.map { id in
            let bytes = try session.execute(readCommand(profile: profile, buttonID: id, layer: layer))
            return try RazerOnboardBinding(bytes: bytes, profile: profile, buttonID: id, layer: layer)
        }
    }
}
