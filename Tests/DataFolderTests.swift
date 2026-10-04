import Foundation

enum DataFolderTests {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func run() throws -> Int {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw Failure(description: message) }
            count += 1
        }
        let fm = FileManager.default
        func makeRoot() throws -> URL {
            let root = fm.temporaryDirectory.appendingPathComponent("opennaga-datafolder-\(UUID().uuidString)")
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            return root
        }
        func write(_ text: String, _ url: URL) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        func read(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }
        func names(_ url: URL) -> [String] { ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).sorted() }

        try check(DataFolder.url.lastPathComponent == "OpenNaga", "Data lives in the OpenNaga folder")
        try check(DataFolder.file("profiles.json").deletingLastPathComponent() == DataFolder.url, "Files resolve inside the data folder")

        // First launch with no older data.
        var root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        var folder = root.appendingPathComponent("OpenNaga")
        var legacy = root.appendingPathComponent("NagaController")
        var result = DataFolder.importLegacyFilesIfNeeded(root: root)
        try check(result.copied.isEmpty && result.failed.isEmpty && !result.alreadyDone, "Fresh install imports nothing")
        try check(names(folder) == [DataFolder.markerName], "Fresh install only writes the marker")
        try check(!fm.fileExists(atPath: legacy.path), "Fresh install does not create the older folder")
        // The older folder appearing later belongs to another app.
        try write("{\"foreign\":true}", legacy.appendingPathComponent("profiles.json"))
        result = DataFolder.importLegacyFilesIfNeeded(root: root)
        try check(result.alreadyDone && result.copied.isEmpty, "A later NagaController folder is not imported")
        try check(!fm.fileExists(atPath: folder.appendingPathComponent("profiles.json").path), "Marker blocks a second import")
        try fm.removeItem(at: root)

        // Upgrade from a build that used the shared folder.
        root = try makeRoot()
        folder = root.appendingPathComponent("OpenNaga")
        legacy = root.appendingPathComponent("NagaController")
        try write("profiles", legacy.appendingPathComponent("profiles.json"))
        try write("backup", legacy.appendingPathComponent("onboard-profile.json"))
        try write("journal", legacy.appendingPathComponent("driver-mode-recovery.json"))
        try write("manual", legacy.appendingPathComponent("onboard-profile.port-0x01131000.bak.json"))
        try write("", legacy.appendingPathComponent("hardware.lock"))
        try write("other", legacy.appendingPathComponent("unrelated.json"))
        let before = names(legacy)
        result = DataFolder.importLegacyFilesIfNeeded(root: root)
        try check(result.failed.isEmpty, "Upgrade import reports no failure")
        try check(result.copied == ["profiles.json", "onboard-profile.json", "driver-mode-recovery.json", "onboard-profile.port-0x01131000.bak.json"], "Upgrade imports profiles, mouse backup, journal and manual backups")
        try check(read(folder.appendingPathComponent("profiles.json")) == "profiles", "Profiles content is preserved")
        try check(read(folder.appendingPathComponent("onboard-profile.json")) == "backup", "Mouse backup content is preserved")
        try check(read(folder.appendingPathComponent("driver-mode-recovery.json")) == "journal", "Driver mode journal is preserved")
        try check(!fm.fileExists(atPath: folder.appendingPathComponent("hardware.lock").path), "The lock file is not imported")
        try check(!fm.fileExists(atPath: folder.appendingPathComponent("unrelated.json").path), "Unrelated files are not imported")
        try check(names(legacy) == before, "The older folder keeps every file")
        try check(read(legacy.appendingPathComponent("profiles.json")) == "profiles", "The older profiles file is untouched")
        // Later edits in the older folder never reach OpenNaga again.
        try write("changed elsewhere", legacy.appendingPathComponent("profiles.json"))
        result = DataFolder.importLegacyFilesIfNeeded(root: root)
        try check(result.alreadyDone, "Import runs once")
        try check(read(folder.appendingPathComponent("profiles.json")) == "profiles", "A second launch does not re-import")
        try fm.removeItem(at: root)

        // Newer data wins over older files.
        root = try makeRoot()
        folder = root.appendingPathComponent("OpenNaga")
        legacy = root.appendingPathComponent("NagaController")
        try write("old", legacy.appendingPathComponent("profiles.json"))
        try write("old backup", legacy.appendingPathComponent("onboard-profile.json"))
        try write("new", folder.appendingPathComponent("profiles.json"))
        result = DataFolder.importLegacyFilesIfNeeded(root: root)
        try check(result.copied == ["onboard-profile.json"], "Only missing files are imported")
        try check(read(folder.appendingPathComponent("profiles.json")) == "new", "Existing data is never overwritten")

        // A failed copy is retried on the next launch.
        try fm.removeItem(at: root)
        root = try makeRoot()
        folder = root.appendingPathComponent("OpenNaga")
        legacy = root.appendingPathComponent("NagaController")
        try write("profiles", legacy.appendingPathComponent("profiles.json"))
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: legacy.appendingPathComponent("profiles.json").path)
        result = DataFolder.importLegacyFilesIfNeeded(root: root)
        try check(result.failed == ["profiles.json"], "An unreadable file is reported")
        try check(!fm.fileExists(atPath: folder.appendingPathComponent(DataFolder.markerName).path), "A failed import leaves no marker")
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: legacy.appendingPathComponent("profiles.json").path)
        result = DataFolder.importLegacyFilesIfNeeded(root: root)
        try check(result.copied == ["profiles.json"] && result.failed.isEmpty, "The next launch completes the import")
        try check(fm.fileExists(atPath: folder.appendingPathComponent(DataFolder.markerName).path), "A completed import writes the marker")
        return count
    }
}
