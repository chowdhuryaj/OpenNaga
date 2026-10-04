import Foundation

// OpenNaga keeps its files in ~/Library/Application Support/OpenNaga.
// Up to 2.3.0 it shared the NagaController folder with the app it started from.
// That folder is read once to import older data and is never written or deleted.
enum DataFolder {
    static let name = "OpenNaga"
    static let legacyName = "NagaController"
    static let importedFiles = ["profiles.json", "onboard-profile.json", "driver-mode-recovery.json"]
    static let markerName = ".legacy-import-done"

    struct ImportResult: Equatable {
        var copied: [String] = []
        var failed: [String] = []
        var alreadyDone = false
    }

    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    static var url: URL { root.appendingPathComponent(name, isDirectory: true) }
    static func file(_ fileName: String) -> URL { url.appendingPathComponent(fileName) }

    // Copies each older file that has no counterpart yet. A failed copy leaves the
    // marker unwritten, so the next launch retries without overwriting newer data.
    @discardableResult
    static func importLegacyFilesIfNeeded(root: URL = DataFolder.root, fileManager: FileManager = .default) -> ImportResult {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        let legacy = root.appendingPathComponent(legacyName, isDirectory: true)
        let marker = folder.appendingPathComponent(markerName)
        var result = ImportResult()
        if fileManager.fileExists(atPath: marker.path) {
            result.alreadyDone = true
            return result
        }
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            NSLog("[DataFolder] Could not create \(folder.path): \(error.localizedDescription)")
            result.failed = [name]
            return result
        }
        var names = importedFiles
        // Hand-made copies of the mouse backup stay next to it.
        let extras = (try? fileManager.contentsOfDirectory(atPath: legacy.path)) ?? []
        names += extras.filter { $0.hasPrefix("onboard-profile.") && $0.hasSuffix(".bak.json") }.sorted()
        for fileName in names {
            let source = legacy.appendingPathComponent(fileName)
            let destination = folder.appendingPathComponent(fileName)
            guard fileManager.fileExists(atPath: source.path), !fileManager.fileExists(atPath: destination.path) else { continue }
            do {
                try fileManager.copyItem(at: source, to: destination)
                result.copied.append(fileName)
            } catch {
                NSLog("[DataFolder] Could not import \(fileName): \(error.localizedDescription)")
                result.failed.append(fileName)
            }
        }
        if result.failed.isEmpty {
            fileManager.createFile(atPath: marker.path, contents: nil)
        }
        if !result.copied.isEmpty {
            NSLog("[DataFolder] Imported from \(legacyName): \(result.copied.joined(separator: ", "))")
        }
        return result
    }
}
