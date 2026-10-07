import Foundation

enum OnboardProfileTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    final class Mouse: RazerTransport {
        static let v2IDs: [UInt8] = [1,2,3,52,53,11,12,64,67,70,73,65,68,71,74,66,69,72,75,9,10]
        static let v3IDs: [UInt8] = v2IDs + [0x6a, 0x39, 0x80] + Array(0x90...0x98)
        var identity: String
        var bindings: [UInt8: [UInt8]] = [:]
        // Layer 1: written entries read byte 2 = 01; untouched ones read the factory keys with 00.
        var hypershift: [UInt8: [UInt8]] = [:]
        var factory: [UInt8: [UInt8]] = [:]
        var sets: [[UInt8]] = []
        var log: [[UInt8]] = [] // command id, profile, button, layer
        var failNextSet = false
        var failAllSets = false
        var failNextHypershiftSet = false
        let ids: [UInt8]
        init(identity: String = "fixture", ids: [UInt8] = v2IDs) {
            self.identity = identity
            self.ids = ids
            for id in ids {
                bindings[id] = [1, id, 0, 1, 1, id, 0, 0, 0, 0]
            }
            for id in UInt8(64)...75 { bindings[id] = [1,id,0,2,1,0,0x1e + id - 64,0,0,0] }
            factory = bindings
        }
        func layer1(_ id: UInt8) -> [UInt8] { hypershift[id] ?? factory[id]! }
        func open() throws {}
        func close() {}
        func exchange(_ request: [UInt8]) throws -> [UInt8] {
            var response = request
            response[0] = 2
            var args = Array(request[8..<(8 + Int(request[5]))])
            switch (request[6], request[7]) {
            case (0, 0x84): args = [0, 0]
            case (2, 0x84): args = [UInt8(ids.count)] + ids
            case (2, 0x8c):
                log.append([0x8c] + args.prefix(3))
                guard args[2] <= 1, var value = args[2] == 1 ? hypershift[args[1]] ?? factory[args[1]] : bindings[args[1]] else {
                    throw Failure(description: "Unknown control")
                }
                value[0] = args[0]
                args = value
            case (2, 0x0c):
                sets.append(args)
                log.append([0x0c] + args.prefix(3))
                // A lost ACK may still follow a successful write.
                if args[2] == 1 { hypershift[args[1]] = args } else { bindings[args[1]] = args }
                if failNextSet || failAllSets || (failNextHypershiftSet && args[2] == 1) {
                    failNextSet = false
                    failNextHypershiftSet = false
                    throw Failure(description: "Lost write ACK")
                }
            default: throw Failure(description: "Unexpected command")
            }
            response.replaceSubrange(8..<(8 + args.count), with: args)
            response[88] = RazerReportCodec.checksum(response)
            return response
        }
    }

    static func run() throws -> Int {
        var count = 0
        func check(_ value: Bool, _ text: String) throws {
            guard value else { throw Failure(description: text) }; count += 1
        }
        func rejects(_ body: () throws -> Void) throws {
            do { try body() } catch { count += 1; return }
            throw Failure(description: "Expected failure")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = root.appendingPathComponent("onboard.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let mouse = Mouse(), session: RazerHardwareSession
        session = RazerHardwareSession(transport: mouse, pause: { _ in })
        let original = mouse.bindings
        let escape = OnboardProfilePlan(name: "Escape", mapping: [1: .keySequence(keys: [KeyStroke(key: "escape", modifiers: [], keyCode: 53)], description: nil)])
        try check(escape.functions[64] == [2,2,0,41,0,0,0], "Escape HID fixture")
        try check(OnboardProfilePlan.keyboard(KeyStroke(key: "c", modifiers: ["cmd", "shift"], keyCode: 8)) == [2,2,10,6,0,0,0], "Modifier and physical-key encoding")
        try check(OnboardProfilePlan.keyboard(KeyStroke(key: "tab", modifiers: ["ctrl"], keyCode: 48)) == [2,2,1,43,0,0,0], "Control Tab")
        try check(OnboardProfilePlan.function(.mouse(action: .button4, description: nil)) == [1,1,4,0,0,0,0], "Button 4 remains a standard mouse button")
        try check(OnboardProfilePlan.function(.mouse(action: .button5, description: nil)) == [1,1,5,0,0,0,0], "Button 5 remains a standard mouse button")
        try check(OnboardProfilePlan.function(.mouse(action: .scrollLeft, description: nil)) == [14,3,104,0,20,0,0], "Horizontal left uses repeat-scroll function, not mouse click")
        try check(OnboardProfilePlan.function(.mouse(action: .scrollRight, description: nil)) == [14,3,105,0,20,0,0], "Horizontal right uses repeat-scroll function, not mouse click")
        try check(OnboardProfilePlan.function(.mouse(action: .dpiUp, description: nil)) == [6,1,1,0,0,0,0], "DPI stage up encoding")
        try check(OnboardProfilePlan.function(.mouse(action: .dpiDown, description: nil)) == [6,1,2,0,0,0,0], "DPI stage down encoding")
        let mapper = ButtonMapper(eventSink: { _ in })
        mapper.updateMapping([13: .mouse(action: .dpiUp, description: nil), 14: .mouse(action: .dpiDown, description: nil)])
        try check(!mapper.hasMapping(buttonIndex: 13) && !mapper.hasMapping(buttonIndex: 14), "Native DPI actions are not intercepted by software")
        try check(OnboardProfilePlan.keyboardUsages[123] == 0x50, "Left arrow position")
        try check(OnboardProfilePlan.buttonIDs[10] == 0x49 && OnboardProfilePlan.buttonIDs[12] == 0x4b, "Grid order independent of enumeration")
        for action: ActionType in [.systemCommand(command: "true", description: nil), .application(path: "/test", description: nil), .macro(steps: [], description: nil), .profileSwitch(profile: "Other", description: nil), .keySequence(keys: [], description: nil), .keySequence(keys: [KeyStroke(key: "a", modifiers: ["fn"])], description: nil)] {
            let invalid = OnboardProfilePlan(name: "Invalid", mapping: [1: action])
            try check(!invalid.isSupported && !invalid.issues.isEmpty, "Unsupported action is visible")
            try rejects { try OnboardProfileStore.save(invalid, session: session, identity: mouse.identity, at: url) }
        }
        try check(mouse.sets.isEmpty && !FileManager.default.fileExists(atPath: url.path), "Invalid plans leave hardware and journal untouched")
        try OnboardProfileStore.save(escape, session: session, identity: mouse.identity, at: url)
        try check(mouse.sets.count == 1, "Only changed control is written")
        let state = try OnboardProfileStore.load(from: url)
        try check(!state.pending && state.name == "Escape" && state.original.count == 21, "Successful save stores a complete backup")
        try check(mouse.bindings[64] == [1,64,0,2,2,0,41,0,0,0], "Stored Escape descriptor")
        try OnboardProfileStore.save(escape, session: session, identity: mouse.identity, at: url)
        try check(mouse.sets.count == 1, "Identical save avoids flash writes")
        let next = OnboardProfilePlan(name: "Next", mapping: [2: .mouse(action: .button5, description: nil)])
        try OnboardProfileStore.save(next, session: session, identity: mouse.identity, at: url)
        try check(mouse.bindings[64] == original[64], "Unassigned controls return to the original baseline on profile replacement")
        try check(OnboardProfileStore.load(from: url).original == state.original, "Original backup survives profile replacements")
        let priorData = try Data(contentsOf: url), priorBindings = mouse.bindings
        mouse.failNextSet = true
        try rejects { try OnboardProfileStore.save(escape, session: session, identity: mouse.identity, at: url) }
        try check(mouse.bindings == priorBindings, "Lost ACK rolls back actual hardware changes")
        try check(Data(contentsOf: url) == priorData, "Rollback preserves the previous journal byte for byte")
        let setCount = mouse.sets.count
        try rejects { try OnboardProfileStore.restore(session: session, identity: "other-device", at: url) }
        try check(mouse.sets.count == setCount, "Wrong receiver cannot restore")
        try check(OnboardProfileStore.sameReceiver("1532:00b4:18026496", "1532:00b4:18022400"), "Same receiver on another USB port or hub")
        try check(!OnboardProfileStore.sameReceiver("1532:00b4:18022400", "1532:00b5:18022400"), "Different receiver model is rejected")
        try OnboardProfileStore.restore(session: session, identity: mouse.identity, at: url)
        try check(mouse.bindings == original, "Restore recovers every original descriptor")
        try check(!FileManager.default.fileExists(atPath: url.path), "Verified restoration removes the hardware-mode gate")
        mouse.failAllSets = true
        try rejects { try OnboardProfileStore.save(escape, session: session, identity: mouse.identity, at: url) }
        try check(OnboardProfileStore.load(from: url).pending, "Failed rollback keeps a pending recovery journal")
        mouse.failAllSets = false
        try rejects { try OnboardProfileStore.save(escape, session: session, identity: mouse.identity, at: url) }
        try OnboardProfileStore.restore(session: session, identity: mouse.identity, at: url)
        try check(mouse.bindings == original, "Manual recovery after interrupted writes")
        let escapeAction = ActionType.keySequence(keys: [KeyStroke(key: "escape", modifiers: [], keyCode: 53)], description: nil)
        let extras = OnboardProfilePlan(name: "Extras", mapping: [1: escapeAction, 20: escapeAction, 21: escapeAction, 22: escapeAction])
        try check(extras.isSupported && [0x6a, 0x39, 0x80].allSatisfy { extras.functions[$0] == [2,2,0,41,0,0,0] }, "V3 Pro extras 20 to 22 map to 0x6a, 0x39, 0x80")
        let setsBefore = mouse.sets.count
        try check(OnboardProfileStore.save(extras, session: session, identity: mouse.identity, at: url) == [20, 21, 22], "V2 save skips and lists the V3-only buttons")
        try check(mouse.sets.dropFirst(setsBefore).map { $0[1] } == [64], "V2 save writes only controls the mouse listed")
        try OnboardProfileStore.restore(session: session, identity: mouse.identity, at: url)
        try check(mouse.bindings == original, "Restore after a save with skipped buttons")
        count += try hypershift(mouse: mouse, session: session, root: root, escape: escapeAction)
        return count
    }

    static func hypershift(mouse: Mouse, session: RazerHardwareSession, root: URL, escape: ActionType) throws -> Int {
        var count = 0
        func check(_ value: Bool, _ text: String) throws {
            guard value else { throw Failure(description: text) }; count += 1
        }
        func rejects(_ body: () throws -> Void) throws {
            do { try body() } catch { count += 1; return }
            throw Failure(description: "Expected failure")
        }
        let hyper = ActionType.mouse(action: .hypershift, description: nil)
        let f1 = ActionType.keySequence(keys: [KeyStroke(key: "f1", modifiers: [], keyCode: 122)], description: nil)
        let block: [UInt8] = [0x0c, 1, 0x39, 0, 0, 0, 0]

        // Plan
        let plan = OnboardProfilePlan(name: "Hyper", mapping: [1: escape, 21: hyper], hypershift: [1: f1, 2: escape])
        try check(plan.isSupported && plan.functions[0x39] == block && plan.functions.count == 2, "Hypershift block on the ring-finger button")
        try check(plan.hypershiftFunctions == [64: [2,2,0,0x3a,0,0,0], 65: [2,2,0,41,0,0,0]], "Hypershift layer encoded apart from the normal layer")
        for bad in [OnboardProfilePlan(name: "Bad", mapping: [20: hyper]), OnboardProfilePlan(name: "Bad", mapping: [1: hyper]),
                    OnboardProfilePlan(name: "Bad", mapping: [1: escape], hypershift: [21: hyper])] {
            try check(!bad.isSupported && bad.issues.count == 1 && bad.issues[0].contains("Hypershift"), "Hypershift elsewhere is an issue")
        }
        let mapper = ButtonMapper(eventSink: { _ in })
        mapper.updateMapping([21: hyper])
        try check(!mapper.hasMapping(buttonIndex: 21), "Software remapping ignores Hypershift")

        // Profiles
        let legacy = try JSONDecoder().decode(ProfilesFile.self, from: Data(#"{"profiles":{"Old":{"buttons":{"1":{"type":"disabled"}}}}}"#.utf8))
        try check(legacy.profiles["Old"]?.hypershift == nil, "Old profiles.json loads without Hypershift")
        try check(!String(decoding: JSONEncoder().encode(legacy), as: UTF8.self).contains("hypershift"), "Untouched profile re-encodes without the key")
        let suite = "OnboardProfileTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); ButtonMapper.shared.updateMapping([:]) }
        let config = ConfigManager(storageURL: root.appendingPathComponent("profiles.json"), defaults: defaults)
        _ = config.createProfile(name: "Layers")
        config.setAction(forButton: 1, action: f1, layer: 1)
        try check(config.mappingForCurrentProfile(layer: 1) == [1: f1] && config.mappingForCurrentProfile().isEmpty, "Layers are stored apart")
        let reloaded = ConfigManager(storageURL: root.appendingPathComponent("profiles.json"), defaults: defaults)
        reloaded.load()
        try check(reloaded.mappingForCurrentProfile(layer: 1) == [1: f1], "Hypershift layer survives reload")
        config.setAction(forButton: 1, action: nil, layer: 1)
        try check(config.profiles["Layers"]?.hypershift == nil, "Clearing the last Hypershift action removes the key")

        // V3 Pro save
        let v3 = Mouse(identity: "1532:00e7:1", ids: Mouse.v3IDs)
        let v3Session = RazerHardwareSession(transport: v3, pause: { _ in })
        let url = root.appendingPathComponent("v3.json")
        let original = v3.bindings
        try check(OnboardProfileStore.save(plan, session: v3Session, identity: v3.identity, at: url).isEmpty, "V3 save skips nothing")
        let firstSet = v3.log.firstIndex { $0[0] == 0x0c } ?? 0
        try check(v3.log[..<firstSet].filter { $0[0] == 0x8c && $0[1] == 1 && $0[3] == 1 }.count == 33, "Layer 1 is backed up before the first write")
        try check(v3.sets.map { [$0[1], $0[2]] } == [[64, 0], [0x39, 0], [64, 1], [65, 1]], "Changed layer 0, then changed layer 1")
        let afterWrites = v3.log[firstSet...]
        try check(afterWrites.filter { $0[0] == 0x8c && $0[1] == 1 }.count == 4, "Each write is verified on bank 1 in its layer")
        try check(afterWrites.filter { $0[0] == 0x8c && $0[1] == 0 && $0[3] == 0 }.count == 33 &&
                  afterWrites.filter { $0[0] == 0x8c && $0[1] == 0 && $0[3] == 1 }.count == 2, "Bank 0 verified for every layer 0 target and the written layer 1 ones")
        try check(v3.hypershift[64] == [1, 64, 1, 2, 2, 0, 0x3a, 0, 0, 0] && v3.bindings[0x39] == [1, 0x39, 0] + block, "Stored descriptors")
        let state = try OnboardProfileStore.load(from: url)
        try check(state.hypershift == Mouse.v3IDs.map { v3.factory[$0]! }, "Journal keeps the untouched layer 1 (byte 2 = 00)")
        try OnboardProfileStore.save(plan, session: v3Session, identity: v3.identity, at: url)
        try check(v3.sets.count == 4, "Identical save rewrites neither layer (readback byte 2 = 01 accepted)")
        try check(!v3.sets.contains { $0[1] == 0x6a }, "Control 0x6a is never rewritten when unchanged")

        // Failure in the middle of the layer 1 writes
        let priorData = try Data(contentsOf: url), priorBindings = v3.bindings, priorLayer1 = Mouse.v3IDs.map(v3.layer1)
        let other = OnboardProfilePlan(name: "Other", mapping: [1: f1, 21: hyper], hypershift: [1: escape, 3: f1])
        v3.failNextHypershiftSet = true
        try rejects { try OnboardProfileStore.save(other, session: v3Session, identity: v3.identity, at: url) }
        try check(v3.sets.suffix(6).map { [$0[1], $0[2]] } == [[64, 0], [64, 1], [66, 1], [65, 1], [64, 1], [64, 0]], "Rollback covers both layers in reverse order")
        try check(v3.bindings == priorBindings && zip(Mouse.v3IDs.map(v3.layer1), priorLayer1).allSatisfy { OnboardProfileStore.same($0, $1) },
                  "Failed layer 1 write rolls back both layers")
        try check(Data(contentsOf: url) == priorData, "Rollback keeps the previous journal byte for byte")

        // Restore
        let setsBeforeRestore = v3.sets.count
        try OnboardProfileStore.restore(session: v3Session, identity: v3.identity, at: url)
        try check(v3.bindings == original && Mouse.v3IDs.allSatisfy { OnboardProfileStore.same(v3.layer1($0), v3.factory[$0]!) }, "Restore recovers both layers")
        try check(v3.sets.dropFirst(setsBeforeRestore).contains { $0[2] == 1 } && v3.hypershift[64]?[2] == 1, "Restored Hypershift entries keep the stored flag")
        try check(!FileManager.default.fileExists(atPath: url.path), "Restore removes the journal")

        // Journals written before Hypershift support
        func stripHypershift() throws {
            var old = try OnboardProfileStore.load(from: url)
            old.hypershift = nil
            try JSONEncoder().encode(old).write(to: url)
            try check(String(decoding: Data(contentsOf: url), as: UTF8.self).contains("hypershift") == false, "Old journal fixture")
        }
        let normalOnly = OnboardProfilePlan(name: "Normal", mapping: [1: escape])
        try OnboardProfileStore.save(normalOnly, session: v3Session, identity: v3.identity, at: url)
        try stripHypershift()
        try check(try OnboardProfileStore.load(from: url).hypershift == nil, "Old journal without Hypershift loads")
        try OnboardProfileStore.save(plan, session: v3Session, identity: v3.identity, at: url)
        // 64 to 66 were written earlier (save, rollback, restore), so the fresh read has byte 2 = 01 there.
        let fresh = try OnboardProfileStore.load(from: url).hypershift ?? []
        try check(fresh.map { $0[2] } == Mouse.v3IDs.map { [64, 65, 66].contains($0) ? 1 : 0 } &&
                  zip(fresh, Mouse.v3IDs).allSatisfy { OnboardProfileStore.same($0, v3.factory[$1]!) }, "Missing journal layer 1 is taken from the fresh read")
        try OnboardProfileStore.restore(session: v3Session, identity: v3.identity, at: url)
        try OnboardProfileStore.save(normalOnly, session: v3Session, identity: v3.identity, at: url)
        try stripHypershift()
        let logMark = v3.log.count
        try OnboardProfileStore.restore(session: v3Session, identity: v3.identity, at: url)
        try check(v3.bindings == original && !v3.log.dropFirst(logMark).contains { $0[3] == 1 }, "Old journal restores layer 0 only")
        var corrupt = state
        corrupt.hypershift = Array(state.hypershift!.prefix(5))
        try JSONEncoder().encode(corrupt).write(to: url)
        try rejects { _ = try OnboardProfileStore.load(from: url) }
        try FileManager.default.removeItem(at: url)

        // V2 HyperSpeed: layer 1 unverified, never touched
        let v2URL = root.appendingPathComponent("v2.json")
        mouse.log.removeAll()
        let v2Plan = OnboardProfilePlan(name: "V2", mapping: [1: escape, 21: hyper], hypershift: [2: f1])
        try check(OnboardProfileStore.save(v2Plan, session: session, identity: mouse.identity, at: v2URL) == [21], "V2 skips the Hypershift button")
        try check(OnboardProfileStore.skipsHypershift(v2Plan, identity: mouse.identity) && !OnboardProfileStore.skipsHypershift(v2Plan, identity: v3.identity),
                  "V2 save reports the Hypershift skip")
        try check(OnboardProfileStore.load(from: v2URL).hypershift == nil, "V2 journal has no layer 1")
        try OnboardProfileStore.restore(session: session, identity: mouse.identity, at: v2URL)
        try check(!mouse.log.contains { $0[3] != 0 } && !mouse.sets.contains { $0[1] == 0x39 }, "V2 sends no layer 1 traffic")
        try check(!String(decoding: JSONEncoder().encode(OnboardProfileStore.State(identity: "a", original: [], name: "n", pending: false)), as: UTF8.self).contains("hypershift"),
                  "V2 journal format unchanged")
        return count
    }
}
